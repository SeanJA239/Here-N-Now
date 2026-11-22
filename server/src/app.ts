import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { mkdirSync, readFileSync, rmSync, writeFileSync, existsSync, renameSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

export const PAIRING_TTL_MS = 10 * 60 * 1000;
export const OFFLINE_LEASE_MS = 7 * 24 * 60 * 60 * 1000;
export const TOKEN_REDELIVERY_MS = 10 * 60 * 1000;
const MAX_SNAPSHOT_BYTES = 1024 * 1024;
const MAX_ASSET_BYTES = 8 * 1024 * 1024;
const ASSET_GRACE_MS = 24 * 60 * 60 * 1000;
const PAIRING_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const FAILED_PAIRING_LIMIT = 10;
const FAILED_PAIRING_WINDOW_MS = 10 * 60 * 1000;
const MAX_WAIT_SECONDS = 25;

type Role = "caregiver" | "display" | "contributor";
const PLAYLOG_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
type WipeState = "none" | "pending" | "confirmed";

interface DeviceRow {
  id: string;
  family_id: string;
  role: Role;
  name: string;
  installation_id: string;
  token_hash: string;
  created_at: number;
  revoked_at: number | null;
  wipe_state: WipeState;
  last_seen_at: number | null;
  applied_version: number | null;
  applied_controls_rev: number | null;
  applied_at: number | null;
  report: string | null;
}

interface FamilyRow {
  id: string;
  name: string;
  created_at: number;
  recovery_hash: string;
  rev: number;
  current_version: number;
  snapshot: string | null;
  published_at: number | null;
  published_by: string | null;
  controls: string;
  controls_rev: number;
  deleted_at: number | null;
}

interface PairingRow {
  code: string;
  family_id: string;
  created_by: string;
  created_at: number;
  expires_at: number;
  state: "open" | "claimed" | "approved" | "rejected";
  role: Role;
  claim_id: string | null;
  claim_secret_hash: string | null;
  claim_installation_id: string | null;
  claim_device_name: string | null;
  claimed_at: number | null;
  device_id: string | null;
  issued_token: string | null;
  approved_at: number | null;
}

interface ProposalRow {
  id: string;
  family_id: string;
  device_id: string;
  device_name: string;
  kind: "recording" | "photo" | "event";
  payload: string;
  asset_refs: string;
  created_at: number;
  state: "pending" | "accepted" | "declined";
  resolved_at: number | null;
}

export class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly extra: Record<string, unknown>;

  constructor(status: number, code: string, extra: Record<string, unknown> = {}) {
    super(code);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

const sha256 = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
const newId = () => randomBytes(12).toString("base64url");
const newToken = () => "hn_" + randomBytes(32).toString("base64url");

function safeEqualHex(a: string, b: string) {
  const left = Buffer.from(a, "hex");
  const right = Buffer.from(b, "hex");
  return left.length === right.length && timingSafeEqual(left, right);
}

function randomCode(groups: number, size: number) {
  const parts: string[] = [];
  for (let g = 0; g < groups; g++) {
    let part = "";
    for (let i = 0; i < size; i++) part += PAIRING_ALPHABET[randomInt(PAIRING_ALPHABET.length)];
    parts.push(part);
  }
  return parts.join("-");
}

/** Report fields that change on every sync (clock readings, lease renewal) must not wake waiting clients. */
const VOLATILE_REPORT_KEYS = new Set(["deviceTime", "leaseExpiresAt"]);

function reportFacts(report: string | null) {
  if (!report) return "";
  try {
    const parsed = JSON.parse(report) as Record<string, unknown>;
    return JSON.stringify(Object.keys(parsed).sort().filter((k) => !VOLATILE_REPORT_KEYS.has(k)).map((k) => [k, parsed[k]]));
  } catch {
    return report;
  }
}

/** ISO 8601 without milliseconds, which Foundation's default ISO 8601 decoder accepts. */
const isoSeconds = (ms: number) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(".000Z", "Z");

export const normalizeCode = (value: unknown) =>
  typeof value === "string" ? value.toUpperCase().replace(/[^A-Z0-9]/g, "") : "";

function requireString(body: Record<string, unknown>, key: string, max = 120) {
  const value = body[key];
  if (typeof value !== "string" || value.trim() === "" || value.length > max) {
    throw new HttpError(400, "invalid_field", { field: key });
  }
  return value.trim();
}

export interface AppOptions {
  dataDir: string;
  now?: () => number;
}

export class HereNowServer {
  readonly db: DatabaseSync;
  private readonly assetsDir: string;
  private readonly now: () => number;
  private readonly waiters = new Map<string, Set<() => void>>();
  private readonly failedPairing = new Map<string, number[]>();

  constructor(options: AppOptions) {
    mkdirSync(options.dataDir, { recursive: true });
    this.assetsDir = join(options.dataDir, "assets");
    mkdirSync(this.assetsDir, { recursive: true });
    this.now = options.now ?? Date.now;
    this.db = new DatabaseSync(join(options.dataDir, "here-now.sqlite"));
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS families (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at INTEGER NOT NULL,
        recovery_hash TEXT NOT NULL, rev INTEGER NOT NULL DEFAULT 1,
        current_version INTEGER NOT NULL DEFAULT 0, snapshot TEXT, published_at INTEGER, published_by TEXT,
        controls TEXT NOT NULL DEFAULT '{"soundPaused":false,"displayPaused":false}',
        controls_rev INTEGER NOT NULL DEFAULT 0, deleted_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY, family_id TEXT NOT NULL REFERENCES families(id),
        role TEXT NOT NULL, name TEXT NOT NULL, installation_id TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL, revoked_at INTEGER,
        wipe_state TEXT NOT NULL DEFAULT 'none', last_seen_at INTEGER,
        applied_version INTEGER, applied_controls_rev INTEGER, applied_at INTEGER, report TEXT
      );
      CREATE TABLE IF NOT EXISTS pairing_codes (
        code TEXT PRIMARY KEY, family_id TEXT NOT NULL REFERENCES families(id), created_by TEXT NOT NULL,
        created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, state TEXT NOT NULL,
        claim_id TEXT UNIQUE, claim_secret_hash TEXT, claim_installation_id TEXT, claim_device_name TEXT,
        claimed_at INTEGER, device_id TEXT, issued_token TEXT, approved_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS assets (
        family_id TEXT NOT NULL REFERENCES families(id), sha256 TEXT NOT NULL, size INTEGER NOT NULL,
        mime TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (family_id, sha256)
      );
      CREATE TABLE IF NOT EXISTS publishes (
        family_id TEXT NOT NULL, publish_id TEXT NOT NULL, version INTEGER NOT NULL,
        PRIMARY KEY (family_id, publish_id)
      );
      CREATE TABLE IF NOT EXISTS proposals (
        id TEXT PRIMARY KEY, family_id TEXT NOT NULL REFERENCES families(id), device_id TEXT NOT NULL,
        device_name TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, asset_refs TEXT NOT NULL,
        created_at INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'pending', resolved_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS play_log (
        family_id TEXT NOT NULL, device_id TEXT NOT NULL, at INTEGER NOT NULL, kind TEXT NOT NULL,
        trigger TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY (device_id, at, kind)
      );
      CREATE TABLE IF NOT EXISTS play_coverage (
        family_id TEXT NOT NULL, device_id TEXT NOT NULL, start INTEGER NOT NULL, end INTEGER NOT NULL,
        PRIMARY KEY (device_id, start)
      );
    `);
    const pairingColumns = this.db.prepare("PRAGMA table_info(pairing_codes)").all() as { name: string }[];
    if (!pairingColumns.some((c) => c.name === "role")) {
      this.db.exec("ALTER TABLE pairing_codes ADD COLUMN role TEXT NOT NULL DEFAULT 'display'");
    }
  }

  close() {
    for (const set of this.waiters.values()) for (const wake of set) wake();
    this.db.close();
  }

  private tx<T>(fn: () => T): T {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const result = fn();
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  private bump(familyId: string) {
    this.db.prepare("UPDATE families SET rev = rev + 1 WHERE id = ?").run(familyId);
    const set = this.waiters.get(familyId);
    if (set) {
      this.waiters.delete(familyId);
      queueMicrotask(() => set.forEach((wake) => wake()));
    }
  }

  private family(id: string) {
    return this.db.prepare("SELECT * FROM families WHERE id = ?").get(id) as FamilyRow | undefined;
  }

  private authenticate(req: IncomingMessage, { allowRevoked = false } = {}) {
    const header = req.headers.authorization ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : "";
    if (!token) throw new HttpError(401, "missing_token");
    const device = this.db.prepare("SELECT * FROM devices WHERE token_hash = ?").get(sha256(token)) as
      | DeviceRow
      | undefined;
    if (!device) throw new HttpError(401, "invalid_token");
    const family = this.family(device.family_id)!;
    if (!allowRevoked) {
      if (family.deleted_at) throw new HttpError(410, "family_deleted");
      if (device.revoked_at) throw new HttpError(410, "device_revoked");
    }
    return { device, family };
  }

  private requireCaregiver(req: IncomingMessage) {
    const auth = this.authenticate(req);
    if (auth.device.role !== "caregiver") throw new HttpError(403, "caregiver_only");
    return auth;
  }

  private noteFailedPairing(client: string) {
    const list = (this.failedPairing.get(client) ?? []).filter((t) => t > this.now() - FAILED_PAIRING_WINDOW_MS);
    list.push(this.now());
    this.failedPairing.set(client, list);
  }

  private checkPairingRate(client: string) {
    const list = (this.failedPairing.get(client) ?? []).filter((t) => t > this.now() - FAILED_PAIRING_WINDOW_MS);
    if (list.length >= FAILED_PAIRING_LIMIT) throw new HttpError(429, "too_many_attempts");
  }

  private lookupCode(rawCode: unknown, client: string) {
    this.checkPairingRate(client);
    const code = normalizeCode(rawCode);
    const row = this.db.prepare("SELECT * FROM pairing_codes WHERE code = ?").get(code) as PairingRow | undefined;
    if (!row) {
      this.noteFailedPairing(client);
      throw new HttpError(404, "pairing_code_invalid");
    }
    const family = this.family(row.family_id);
    if (!family || family.deleted_at) {
      this.noteFailedPairing(client);
      throw new HttpError(404, "pairing_code_invalid");
    }
    if (row.expires_at <= this.now() && row.state === "open") {
      this.noteFailedPairing(client);
      throw new HttpError(410, "pairing_code_expired");
    }
    return { row, family };
  }

  private deviceView(device: DeviceRow) {
    return {
      id: device.id,
      role: device.role,
      name: device.name,
      createdAt: device.created_at,
      revokedAt: device.revoked_at,
      wipeState: device.wipe_state,
      lastSeenAt: device.last_seen_at,
      appliedVersion: device.applied_version,
      appliedControlsRev: device.applied_controls_rev,
      appliedAt: device.applied_at,
      leaseExpiresAt: device.role === "display" && device.last_seen_at ? device.last_seen_at + OFFLINE_LEASE_MS : null,
      report: device.report ? JSON.parse(device.report) : null,
    };
  }

  private familyState(family: FamilyRow, selfId: string) {
    const devices = this.db
      .prepare("SELECT * FROM devices WHERE family_id = ? ORDER BY created_at")
      .all(family.id) as unknown as DeviceRow[];
    const claims = this.db
      .prepare("SELECT * FROM pairing_codes WHERE family_id = ? AND state = 'claimed' AND claimed_at > ?")
      .all(family.id, this.now() - PAIRING_TTL_MS) as unknown as PairingRow[];
    return {
      family: { id: family.id, name: family.name, createdAt: family.created_at, deletedAt: family.deleted_at },
      rev: family.rev,
      currentVersion: family.current_version,
      publishedAt: family.published_at,
      publishedBy: family.published_by,
      snapshot: family.snapshot ? JSON.parse(family.snapshot) : null,
      controls: JSON.parse(family.controls),
      controlsRev: family.controls_rev,
      selfDeviceId: selfId,
      devices: devices.map((d) => this.deviceView(d)),
      pendingClaims: claims.map((c) => ({
        claimId: c.claim_id,
        deviceName: c.claim_device_name,
        claimedAt: c.claimed_at,
        code: c.code,
        role: c.role,
      })),
      proposals: (this.db
        .prepare("SELECT * FROM proposals WHERE family_id = ? AND state = 'pending' ORDER BY created_at")
        .all(family.id) as unknown as ProposalRow[]).map((p) => this.proposalView(p)),
      serverTime: this.now(),
    };
  }

  private async waitForChange(familyId: string, knownRev: number, waitSeconds: number) {
    const family = this.family(familyId);
    if (!family || family.rev !== knownRev || waitSeconds <= 0) return;
    await new Promise<void>((resolve) => {
      const set = this.waiters.get(familyId) ?? new Set();
      this.waiters.set(familyId, set);
      const wake = () => {
        clearTimeout(timer);
        set.delete(wake);
        resolve();
      };
      const timer = setTimeout(wake, Math.min(waitSeconds, MAX_WAIT_SECONDS) * 1000);
      set.add(wake);
    });
  }

  createFamily(body: Record<string, unknown>) {
    const name = requireString(body, "familyName", 40);
    const installationId = requireString(body, "installationId");
    const deviceName = requireString(body, "deviceName", 60);
    const recoveryKey = randomCode(4, 5);
    const token = newToken();
    const familyId = newId();
    const deviceId = newId();
    this.tx(() => {
      this.db
        .prepare("INSERT INTO families (id, name, created_at, recovery_hash) VALUES (?, ?, ?, ?)")
        .run(familyId, name, this.now(), sha256(normalizeCode(recoveryKey)));
      this.db
        .prepare(
          "INSERT INTO devices (id, family_id, role, name, installation_id, token_hash, created_at) VALUES (?, ?, 'caregiver', ?, ?, ?, ?)",
        )
        .run(deviceId, familyId, deviceName, installationId, sha256(token), this.now());
    });
    return { familyId, deviceId, token, recoveryKey };
  }

  recover(body: Record<string, unknown>, client: string) {
    this.checkPairingRate(client);
    const key = normalizeCode(body.recoveryKey);
    const installationId = requireString(body, "installationId");
    const deviceName = requireString(body, "deviceName", 60);
    const family = this.db
      .prepare("SELECT * FROM families WHERE recovery_hash = ? AND deleted_at IS NULL")
      .get(sha256(key)) as FamilyRow | undefined;
    if (!family) {
      this.noteFailedPairing(client);
      throw new HttpError(404, "recovery_key_invalid");
    }
    const recoveryKey = randomCode(4, 5);
    const token = newToken();
    const deviceId = newId();
    this.tx(() => {
      this.db
        .prepare(
          "UPDATE devices SET revoked_at = ?, wipe_state = 'pending' WHERE family_id = ? AND role = 'caregiver' AND revoked_at IS NULL",
        )
        .run(this.now(), family.id);
      this.db
        .prepare(
          "INSERT INTO devices (id, family_id, role, name, installation_id, token_hash, created_at) VALUES (?, ?, 'caregiver', ?, ?, ?, ?)",
        )
        .run(deviceId, family.id, deviceName, installationId, sha256(token), this.now());
      this.db.prepare("UPDATE families SET recovery_hash = ? WHERE id = ?").run(sha256(normalizeCode(recoveryKey)), family.id);
      this.bump(family.id);
    });
    return { familyId: family.id, deviceId, token, recoveryKey };
  }

  async getFamily(req: IncomingMessage, query: URLSearchParams) {
    const { device, family } = this.requireCaregiver(req);
    const waitRev = Number(query.get("waitRev"));
    if (Number.isFinite(waitRev) && query.has("waitRev")) {
      await this.waitForChange(family.id, waitRev, Number(query.get("wait") ?? MAX_WAIT_SECONDS));
    }
    this.db.prepare("UPDATE devices SET last_seen_at = ? WHERE id = ?").run(this.now(), device.id);
    return this.familyState(this.family(family.id)!, device.id);
  }

  publish(req: IncomingMessage, body: Record<string, unknown>) {
    const { device, family } = this.requireCaregiver(req);
    const publishId = requireString(body, "publishId");
    const baseVersion = body.baseVersion;
    const snapshot = body.snapshot;
    if (typeof baseVersion !== "number" || !snapshot || typeof snapshot !== "object") {
      throw new HttpError(400, "invalid_publish");
    }
    const serialized = JSON.stringify(snapshot);
    if (serialized.length > MAX_SNAPSHOT_BYTES) throw new HttpError(413, "snapshot_too_large");
    return this.tx(() => {
      const previous = this.db
        .prepare("SELECT version FROM publishes WHERE family_id = ? AND publish_id = ?")
        .get(family.id, publishId) as { version: number } | undefined;
      if (previous) return { version: previous.version, duplicate: true };
      const current = this.family(family.id)!;
      if (current.current_version !== baseVersion) {
        throw new HttpError(409, "version_conflict", {
          currentVersion: current.current_version,
          snapshot: current.snapshot ? JSON.parse(current.snapshot) : null,
        });
      }
      const refs = (snapshot as { assetRefs?: unknown }).assetRefs;
      const assetRefs = Array.isArray(refs) ? refs.filter((r): r is string => typeof r === "string") : [];
      const missing = assetRefs.filter(
        (sha) => !this.db.prepare("SELECT 1 FROM assets WHERE family_id = ? AND sha256 = ?").get(family.id, sha),
      );
      if (missing.length) throw new HttpError(422, "missing_assets", { missingAssets: missing });
      const version = current.current_version + 1;
      this.db
        .prepare("UPDATE families SET current_version = ?, snapshot = ?, published_at = ?, published_by = ? WHERE id = ?")
        .run(version, serialized, this.now(), device.name, family.id);
      this.db.prepare("INSERT INTO publishes (family_id, publish_id, version) VALUES (?, ?, ?)").run(family.id, publishId, version);
      this.collectAssets(family.id, new Set(assetRefs));
      this.bump(family.id);
      return { version, duplicate: false };
    });
  }

  private collectAssets(familyId: string, keepPublished: Set<string>) {
    const keep = new Set(keepPublished);
    const pending = this.db
      .prepare("SELECT asset_refs FROM proposals WHERE family_id = ? AND state = 'pending'")
      .all(familyId) as { asset_refs: string }[];
    for (const p of pending) for (const sha of JSON.parse(p.asset_refs) as string[]) keep.add(sha);
    const rows = this.db.prepare("SELECT sha256, created_at FROM assets WHERE family_id = ?").all(familyId) as {
      sha256: string;
      created_at: number;
    }[];
    for (const row of rows) {
      if (keep.has(row.sha256) || row.created_at > this.now() - ASSET_GRACE_MS) continue;
      this.db.prepare("DELETE FROM assets WHERE family_id = ? AND sha256 = ?").run(familyId, row.sha256);
      rmSync(join(this.assetsDir, familyId, row.sha256), { force: true });
    }
  }

  putAsset(req: IncomingMessage, sha: string, bytes: Buffer) {
    const { device, family } = this.authenticate(req);
    if (device.role === "display") throw new HttpError(403, "caregiver_only");
    if (!/^[0-9a-f]{64}$/.test(sha)) throw new HttpError(400, "invalid_asset_id");
    if (bytes.length === 0 || bytes.length > MAX_ASSET_BYTES) throw new HttpError(413, "asset_size");
    if (sha256(bytes) !== sha) throw new HttpError(400, "asset_hash_mismatch");
    const mime = String(req.headers["content-type"] ?? "application/octet-stream").slice(0, 60);
    const dir = join(this.assetsDir, family.id);
    mkdirSync(dir, { recursive: true });
    const tmp = join(dir, `${sha}.part`);
    writeFileSync(tmp, bytes);
    renameSync(tmp, join(dir, sha));
    this.db
      .prepare(
        "INSERT INTO assets (family_id, sha256, size, mime, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO UPDATE SET created_at = excluded.created_at",
      )
      .run(family.id, sha, bytes.length, mime, this.now());
    return { sha256: sha, size: bytes.length };
  }

  getAsset(req: IncomingMessage, sha: string) {
    const { device, family } = this.authenticate(req);
    if (device.role === "contributor") {
      const own = this.db
        .prepare("SELECT asset_refs FROM proposals WHERE device_id = ?")
        .all(device.id) as { asset_refs: string }[];
      if (!own.some((p) => (JSON.parse(p.asset_refs) as string[]).includes(sha))) throw new HttpError(404, "asset_not_found");
    }
    const row = this.db.prepare("SELECT * FROM assets WHERE family_id = ? AND sha256 = ?").get(family.id, sha) as
      | { mime: string }
      | undefined;
    const path = join(this.assetsDir, family.id, sha);
    if (!row || !existsSync(path)) throw new HttpError(404, "asset_not_found");
    return { mime: row.mime, bytes: readFileSync(path) };
  }

  setControls(req: IncomingMessage, body: Record<string, unknown>) {
    const { family } = this.requireCaregiver(req);
    const current = JSON.parse(family.controls) as Record<string, unknown>;
    const next: Record<string, unknown> = {
      soundPaused: typeof body.soundPaused === "boolean" ? body.soundPaused : current.soundPaused,
      displayPaused: typeof body.displayPaused === "boolean" ? body.displayPaused : current.displayPaused,
      comfortItemID: current.comfortItemID ?? null,
      comfortRequestID: current.comfortRequestID ?? null,
      comfortRequestedAt: current.comfortRequestedAt ?? null,
    };
    // Starting comfort content is a one-off command; the server stamps its own time so a display that was
    // offline can tell the request is stale and must not start playing late.
    if ("comfortItemID" in body) {
      const item = body.comfortItemID;
      if (item !== null && (typeof item !== "string" || item.length > 80)) throw new HttpError(400, "invalid_field", { field: "comfortItemID" });
      next.comfortItemID = item;
      next.comfortRequestID = item === null ? null : newId();
      next.comfortRequestedAt = item === null ? null : isoSeconds(this.now());
    }
    return this.tx(() => {
      this.db
        .prepare("UPDATE families SET controls = ?, controls_rev = controls_rev + 1 WHERE id = ?")
        .run(JSON.stringify(next), family.id);
      this.bump(family.id);
      return { controls: next, controlsRev: family.controls_rev + 1 };
    });
  }

  createPairingCode(req: IncomingMessage, body: Record<string, unknown> = {}) {
    const { device, family } = this.requireCaregiver(req);
    const role: Role = body.role === "contributor" ? "contributor" : "display";
    const code = normalizeCode(randomCode(2, 4));
    const expiresAt = this.now() + PAIRING_TTL_MS;
    this.db
      .prepare(
        "INSERT INTO pairing_codes (code, family_id, created_by, created_at, expires_at, state, role) VALUES (?, ?, ?, ?, ?, 'open', ?)",
      )
      .run(code, family.id, device.name, this.now(), expiresAt, role);
    return { code: `${code.slice(0, 4)}-${code.slice(4)}`, expiresAt, role };
  }

  previewPairing(query: URLSearchParams, client: string) {
    const { row, family } = this.lookupCode(query.get("code"), client);
    if (row.state !== "open") throw new HttpError(409, "pairing_code_consumed");
    return { familyName: family.name, initiatedBy: row.created_by, expiresAt: row.expires_at, role: row.role };
  }

  claimPairing(body: Record<string, unknown>, client: string) {
    const installationId = requireString(body, "installationId");
    const deviceName = requireString(body, "deviceName", 60);
    const claimSecret = requireString(body, "claimSecret", 200);
    if (claimSecret.length < 22) throw new HttpError(400, "invalid_field", { field: "claimSecret" });
    const { row, family } = this.lookupCode(body.code, client);
    if (row.state !== "open") {
      const sameClaim =
        row.claim_installation_id === installationId &&
        row.claim_secret_hash !== null &&
        safeEqualHex(row.claim_secret_hash, sha256(claimSecret));
      if (sameClaim) return { claimId: row.claim_id, familyName: family.name, initiatedBy: row.created_by, role: row.role };
      throw new HttpError(409, "pairing_code_consumed");
    }
    const claimId = newId();
    this.tx(() => {
      this.db
        .prepare(
          "UPDATE pairing_codes SET state = 'claimed', claim_id = ?, claim_secret_hash = ?, claim_installation_id = ?, claim_device_name = ?, claimed_at = ? WHERE code = ? AND state = 'open'",
        )
        .run(claimId, sha256(claimSecret), installationId, deviceName, this.now(), row.code);
      this.bump(family.id);
    });
    return { claimId, familyName: family.name, initiatedBy: row.created_by, role: row.role };
  }

  claimStatus(claimId: string, query: URLSearchParams) {
    const row = this.db.prepare("SELECT * FROM pairing_codes WHERE claim_id = ?").get(claimId) as PairingRow | undefined;
    const secret = query.get("secret") ?? "";
    if (!row || !row.claim_secret_hash || !safeEqualHex(row.claim_secret_hash, sha256(secret))) {
      throw new HttpError(404, "claim_not_found");
    }
    const family = this.family(row.family_id)!;
    if (family.deleted_at) return { state: "rejected" };
    if (row.state === "claimed") {
      if (row.claimed_at! + PAIRING_TTL_MS < this.now()) return { state: "expired" };
      return { state: "pending", familyName: family.name };
    }
    if (row.state === "rejected") return { state: "rejected" };
    const device = this.db.prepare("SELECT * FROM devices WHERE id = ?").get(row.device_id) as unknown as DeviceRow;
    const canRedeliver =
      row.issued_token && device.last_seen_at === null && row.approved_at! + TOKEN_REDELIVERY_MS > this.now();
    return {
      state: "approved",
      familyId: family.id,
      familyName: family.name,
      deviceId: device.id,
      deviceName: device.name,
      role: device.role,
      token: canRedeliver ? row.issued_token : null,
    };
  }

  resolveClaim(req: IncomingMessage, claimId: string, approve: boolean) {
    const { family } = this.requireCaregiver(req);
    const row = this.db.prepare("SELECT * FROM pairing_codes WHERE claim_id = ? AND family_id = ?").get(claimId, family.id) as
      | PairingRow
      | undefined;
    if (!row) throw new HttpError(404, "claim_not_found");
    if (row.state === "approved" && approve) return { state: "approved", deviceId: row.device_id };
    if (row.state !== "claimed") throw new HttpError(409, "claim_not_pending");
    if (row.claimed_at! + PAIRING_TTL_MS < this.now()) throw new HttpError(410, "claim_expired");
    return this.tx(() => {
      if (!approve) {
        this.db.prepare("UPDATE pairing_codes SET state = 'rejected' WHERE code = ?").run(row.code);
        this.bump(family.id);
        return { state: "rejected" };
      }
      const token = newToken();
      const existing = this.db
        .prepare("SELECT * FROM devices WHERE family_id = ? AND installation_id = ? AND role = ? AND revoked_at IS NULL")
        .get(family.id, row.claim_installation_id, row.role) as DeviceRow | undefined;
      let deviceId: string;
      if (existing) {
        deviceId = existing.id;
        this.db
          .prepare("UPDATE devices SET token_hash = ?, name = ?, last_seen_at = NULL WHERE id = ?")
          .run(sha256(token), row.claim_device_name, existing.id);
      } else {
        deviceId = newId();
        this.db
          .prepare(
            "INSERT INTO devices (id, family_id, role, name, installation_id, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
          )
          .run(deviceId, family.id, row.role, row.claim_device_name, row.claim_installation_id, sha256(token), this.now());
      }
      this.db
        .prepare("UPDATE pairing_codes SET state = 'approved', device_id = ?, issued_token = ?, approved_at = ? WHERE code = ?")
        .run(deviceId, token, this.now(), row.code);
      this.bump(family.id);
      return { state: "approved", deviceId };
    });
  }

  registerOwnDisplay(req: IncomingMessage, body: Record<string, unknown>) {
    const { device, family } = this.requireCaregiver(req);
    const deviceName = requireString(body, "deviceName", 60);
    const token = newToken();
    return this.tx(() => {
      const existing = this.db
        .prepare(
          "SELECT id FROM devices WHERE family_id = ? AND installation_id = ? AND role = 'display' AND revoked_at IS NULL",
        )
        .get(family.id, device.installation_id) as { id: string } | undefined;
      const deviceId = existing?.id ?? newId();
      if (existing) {
        this.db.prepare("UPDATE devices SET token_hash = ?, name = ? WHERE id = ?").run(sha256(token), deviceName, deviceId);
      } else {
        this.db
          .prepare(
            "INSERT INTO devices (id, family_id, role, name, installation_id, token_hash, created_at) VALUES (?, ?, 'display', ?, ?, ?, ?)",
          )
          .run(deviceId, family.id, deviceName, device.installation_id, sha256(token), this.now());
      }
      this.bump(family.id);
      return { deviceId, token };
    });
  }

  revokeDevice(req: IncomingMessage, deviceId: string) {
    const { family } = this.requireCaregiver(req);
    const target = this.db.prepare("SELECT * FROM devices WHERE id = ? AND family_id = ?").get(deviceId, family.id) as
      | DeviceRow
      | undefined;
    if (!target) throw new HttpError(404, "device_not_found");
    if (target.revoked_at) return this.deviceView(target);
    if (target.role === "caregiver") {
      const others = this.db
        .prepare("SELECT COUNT(*) AS n FROM devices WHERE family_id = ? AND role = 'caregiver' AND revoked_at IS NULL")
        .get(family.id) as { n: number };
      if (others.n <= 1) throw new HttpError(409, "last_caregiver");
    }
    this.tx(() => {
      this.db.prepare("UPDATE devices SET revoked_at = ?, wipe_state = 'pending' WHERE id = ?").run(this.now(), deviceId);
      this.bump(family.id);
    });
    return this.deviceView(this.db.prepare("SELECT * FROM devices WHERE id = ?").get(deviceId) as unknown as DeviceRow);
  }

  forgetDevice(req: IncomingMessage, deviceId: string) {
    const { family } = this.requireCaregiver(req);
    const target = this.db.prepare("SELECT * FROM devices WHERE id = ? AND family_id = ?").get(deviceId, family.id) as
      | DeviceRow
      | undefined;
    if (!target) throw new HttpError(404, "device_not_found");
    if (!target.revoked_at) throw new HttpError(409, "device_active");
    this.tx(() => {
      this.db.prepare("DELETE FROM devices WHERE id = ?").run(deviceId);
      this.bump(family.id);
    });
    return { forgotten: true };
  }

  async displaySync(req: IncomingMessage, query: URLSearchParams) {
    let auth = this.authenticate(req, { allowRevoked: true });
    if (auth.device.role !== "display") throw new HttpError(403, "display_only");
    const knownRev = Number(query.get("knownRev"));
    if (!auth.device.revoked_at && !auth.family.deleted_at && query.has("knownRev") && Number.isFinite(knownRev)) {
      await this.waitForChange(auth.family.id, knownRev, Number(query.get("wait") ?? MAX_WAIT_SECONDS));
      auth = this.authenticate(req, { allowRevoked: true });
    }
    const { device, family } = auth;
    if (family.deleted_at) return { status: "family_deleted", serverTime: this.now() };
    if (device.revoked_at) return { status: "revoked", serverTime: this.now() };
    this.db.prepare("UPDATE devices SET last_seen_at = ? WHERE id = ?").run(this.now(), device.id);
    const knownVersion = Number(query.get("knownVersion") ?? -1);
    return {
      status: "active",
      rev: family.rev,
      familyId: family.id,
      familyName: family.name,
      deviceId: device.id,
      deviceName: device.name,
      version: family.current_version,
      snapshot: family.current_version !== knownVersion && family.snapshot ? JSON.parse(family.snapshot) : null,
      controls: JSON.parse(family.controls),
      controlsRev: family.controls_rev,
      leaseExpiresAt: this.now() + OFFLINE_LEASE_MS,
      serverTime: this.now(),
    };
  }

  receipt(req: IncomingMessage, body: Record<string, unknown>) {
    const { device, family } = this.authenticate(req);
    if (device.role !== "display") throw new HttpError(403, "display_only");
    const appliedVersion = typeof body.appliedVersion === "number" ? body.appliedVersion : device.applied_version;
    const appliedControlsRev =
      typeof body.appliedControlsRev === "number" ? body.appliedControlsRev : device.applied_controls_rev;
    const report = body.report && typeof body.report === "object" ? JSON.stringify(body.report).slice(0, 16_000) : device.report;
    const changed =
      appliedVersion !== device.applied_version ||
      appliedControlsRev !== device.applied_controls_rev ||
      reportFacts(report) !== reportFacts(device.report);
    if (!changed) {
      this.db.prepare("UPDATE devices SET report = ?, last_seen_at = ? WHERE id = ?").run(report, this.now(), device.id);
    } else {
      this.tx(() => {
        this.db
          .prepare(
            "UPDATE devices SET applied_version = ?, applied_controls_rev = ?, applied_at = CASE WHEN ? THEN ? ELSE applied_at END, report = ?, last_seen_at = ? WHERE id = ?",
          )
          .run(
            appliedVersion,
            appliedControlsRev,
            appliedVersion !== device.applied_version ? 1 : 0,
            this.now(),
            report,
            this.now(),
            device.id,
          );
        this.bump(family.id);
      });
    }
    return { ok: true };
  }

  confirmWipe(req: IncomingMessage) {
    const { device, family } = this.authenticate(req, { allowRevoked: true });
    if (!device.revoked_at && !family.deleted_at) throw new HttpError(409, "device_active");
    this.tx(() => {
      this.db.prepare("UPDATE devices SET wipe_state = 'confirmed', last_seen_at = ? WHERE id = ?").run(this.now(), device.id);
      this.bump(family.id);
    });
    return { wipeState: "confirmed" };
  }

  private proposalView(p: ProposalRow) {
    return {
      id: p.id,
      deviceName: p.device_name,
      kind: p.kind,
      payload: JSON.parse(p.payload),
      assetRefs: JSON.parse(p.asset_refs),
      createdAt: p.created_at,
      state: p.state,
      resolvedAt: p.resolved_at,
    };
  }

  /** Family members can only suggest; nothing they send reaches the patient until the primary caregiver publishes it. */
  submitProposal(req: IncomingMessage, body: Record<string, unknown>) {
    const { device, family } = this.authenticate(req);
    if (device.role !== "contributor") throw new HttpError(403, "contributor_only");
    const kind = body.kind;
    if (kind !== "recording" && kind !== "photo" && kind !== "event") throw new HttpError(400, "invalid_field", { field: "kind" });
    const payload = body.payload && typeof body.payload === "object" ? JSON.stringify(body.payload) : "{}";
    if (payload.length > 4000) throw new HttpError(413, "payload_too_large");
    const refs = Array.isArray(body.assetRefs) ? body.assetRefs.filter((r): r is string => typeof r === "string") : [];
    const missing = refs.filter((sha) => !this.db.prepare("SELECT 1 FROM assets WHERE family_id = ? AND sha256 = ?").get(family.id, sha));
    if (missing.length) throw new HttpError(422, "missing_assets", { missingAssets: missing });
    const id = newId();
    this.tx(() => {
      this.db
        .prepare(
          "INSERT INTO proposals (id, family_id, device_id, device_name, kind, payload, asset_refs, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .run(id, family.id, device.id, device.name, kind, payload, JSON.stringify(refs), this.now());
      this.bump(family.id);
    });
    return { id };
  }

  contributorState(req: IncomingMessage) {
    const { device, family } = this.authenticate(req);
    if (device.role !== "contributor") throw new HttpError(403, "contributor_only");
    this.db.prepare("UPDATE devices SET last_seen_at = ? WHERE id = ?").run(this.now(), device.id);
    const own = this.db
      .prepare("SELECT * FROM proposals WHERE device_id = ? ORDER BY created_at DESC LIMIT 50")
      .all(device.id) as unknown as ProposalRow[];
    return { familyName: family.name, deviceName: device.name, proposals: own.map((p) => this.proposalView(p)) };
  }

  resolveProposal(req: IncomingMessage, id: string, accept: boolean) {
    const { family } = this.requireCaregiver(req);
    const row = this.db.prepare("SELECT * FROM proposals WHERE id = ? AND family_id = ?").get(id, family.id) as ProposalRow | undefined;
    if (!row) throw new HttpError(404, "proposal_not_found");
    if (row.state !== "pending") return this.proposalView(row);
    this.tx(() => {
      this.db
        .prepare("UPDATE proposals SET state = ?, resolved_at = ? WHERE id = ?")
        .run(accept ? "accepted" : "declined", this.now(), id);
      this.bump(family.id);
    });
    return this.proposalView(this.db.prepare("SELECT * FROM proposals WHERE id = ?").get(id) as unknown as ProposalRow);
  }

  /** Optional playback log from a display device. Only start/stop events and foreground spans; kept 7 days. */
  appendPlayLog(req: IncomingMessage, body: Record<string, unknown>) {
    const { device, family } = this.authenticate(req);
    if (device.role !== "display") throw new HttpError(403, "display_only");
    const entries = Array.isArray(body.entries) ? body.entries.slice(0, 500) : [];
    const coverage = Array.isArray(body.coverage) ? body.coverage.slice(0, 200) : [];
    const cutoff = this.now() - PLAYLOG_RETENTION_MS;
    this.tx(() => {
      for (const raw of entries as Record<string, unknown>[]) {
        const at = Date.parse(String(raw.at));
        if (!Number.isFinite(at) || at < cutoff) continue;
        this.db
          .prepare("INSERT OR IGNORE INTO play_log (family_id, device_id, at, kind, trigger, source) VALUES (?, ?, ?, ?, ?, ?)")
          .run(family.id, device.id, at, String(raw.kind).slice(0, 20), String(raw.trigger).slice(0, 20), String(raw.source).slice(0, 20));
      }
      for (const raw of coverage as Record<string, unknown>[]) {
        const start = Date.parse(String(raw.start));
        const end = Date.parse(String(raw.end));
        if (!Number.isFinite(start) || !Number.isFinite(end) || end < start || end < cutoff) continue;
        this.db
          .prepare("INSERT INTO play_coverage (family_id, device_id, start, end) VALUES (?, ?, ?, ?) ON CONFLICT DO UPDATE SET end = MAX(end, excluded.end)")
          .run(family.id, device.id, start, end);
      }
      this.db.prepare("DELETE FROM play_log WHERE family_id = ? AND at < ?").run(family.id, cutoff);
      this.db.prepare("DELETE FROM play_coverage WHERE family_id = ? AND end < ?").run(family.id, cutoff);
    });
    return { ok: true };
  }

  playLog(req: IncomingMessage) {
    const { family } = this.requireCaregiver(req);
    const cutoff = this.now() - PLAYLOG_RETENTION_MS;
    const iso = isoSeconds;
    const entries = this.db
      .prepare("SELECT device_id, at, kind, trigger, source FROM play_log WHERE family_id = ? AND at >= ? ORDER BY at")
      .all(family.id, cutoff) as { device_id: string; at: number; kind: string; trigger: string; source: string }[];
    const coverage = this.db
      .prepare("SELECT device_id, start, end FROM play_coverage WHERE family_id = ? AND end >= ? ORDER BY start")
      .all(family.id, cutoff) as { device_id: string; start: number; end: number }[];
    return {
      entries: entries.map((e) => ({ deviceId: e.device_id, at: iso(e.at), kind: e.kind, trigger: e.trigger, source: e.source })),
      coverage: coverage.map((c) => ({ deviceId: c.device_id, start: iso(c.start), end: iso(c.end) })),
    };
  }

  clearPlayLog(req: IncomingMessage) {
    const { family } = this.requireCaregiver(req);
    this.db.prepare("DELETE FROM play_log WHERE family_id = ?").run(family.id);
    this.db.prepare("DELETE FROM play_coverage WHERE family_id = ?").run(family.id);
    return { cleared: true };
  }

  deleteFamily(req: IncomingMessage) {
    const { device, family } = this.requireCaregiver(req);
    this.tx(() => {
      this.db
        .prepare(
          "UPDATE families SET deleted_at = ?, snapshot = NULL, name = '', controls = '{}', recovery_hash = ? WHERE id = ?",
        )
        .run(this.now(), sha256(randomBytes(16)), family.id);
      this.db.prepare("DELETE FROM assets WHERE family_id = ?").run(family.id);
      this.db.prepare("DELETE FROM pairing_codes WHERE family_id = ?").run(family.id);
      this.db.prepare("DELETE FROM publishes WHERE family_id = ?").run(family.id);
      this.db.prepare("DELETE FROM proposals WHERE family_id = ?").run(family.id);
      this.db.prepare("DELETE FROM play_log WHERE family_id = ?").run(family.id);
      this.db.prepare("DELETE FROM play_coverage WHERE family_id = ?").run(family.id);
      this.db
        .prepare("UPDATE devices SET revoked_at = COALESCE(revoked_at, ?), wipe_state = CASE WHEN wipe_state = 'confirmed' THEN 'confirmed' ELSE 'pending' END, report = NULL WHERE family_id = ?")
        .run(this.now(), family.id);
      this.db.prepare("UPDATE devices SET wipe_state = 'confirmed' WHERE id = ?").run(device.id);
      this.bump(family.id);
    });
    rmSync(join(this.assetsDir, family.id), { recursive: true, force: true });
    return this.deletionStatus(req);
  }

  deletionStatus(req: IncomingMessage) {
    const { family } = this.authenticate(req, { allowRevoked: true });
    if (!family.deleted_at) throw new HttpError(409, "family_active");
    const devices = this.db.prepare("SELECT * FROM devices WHERE family_id = ?").all(family.id) as unknown as DeviceRow[];
    return {
      deletedAt: family.deleted_at,
      devices: devices.map((d) => ({ id: d.id, name: d.name, role: d.role, wipeState: d.wipe_state, lastSeenAt: d.last_seen_at })),
    };
  }
}

async function readBody(req: IncomingMessage, limit: number) {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > limit) throw new HttpError(413, "body_too_large");
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks);
}

async function readJson(req: IncomingMessage) {
  const raw = await readBody(req, MAX_SNAPSHOT_BYTES + 64 * 1024);
  if (raw.length === 0) return {};
  try {
    const value = JSON.parse(raw.toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch {
    throw new HttpError(400, "invalid_json");
  }
}

export function createHandler(app: HereNowServer) {
  return async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", "http://local");
    const path = url.pathname;
    const method = req.method ?? "GET";
    const client = req.socket.remoteAddress ?? "unknown";
    const send = (status: number, payload: unknown) => {
      res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
      res.end(JSON.stringify(payload));
    };
    try {
      let match: RegExpMatchArray | null;
      if (method === "GET" && path === "/healthz") return send(200, { ok: true });
      if (method === "POST" && path === "/v1/families") return send(201, app.createFamily(await readJson(req)));
      if (method === "POST" && path === "/v1/recover") return send(200, app.recover(await readJson(req), client));
      if (method === "GET" && path === "/v1/family") return send(200, await app.getFamily(req, url.searchParams));
      if (method === "DELETE" && path === "/v1/family") return send(200, app.deleteFamily(req));
      if (method === "GET" && path === "/v1/family/deletion") return send(200, app.deletionStatus(req));
      if (method === "POST" && path === "/v1/family/publish") return send(200, app.publish(req, await readJson(req)));
      if (method === "POST" && path === "/v1/family/controls") return send(200, app.setControls(req, await readJson(req)));
      if (method === "POST" && path === "/v1/family/pairing-codes") return send(201, app.createPairingCode(req, await readJson(req)));
      if ((match = path.match(/^\/v1\/family\/proposals\/([\w-]+)\/(accept|decline)$/)) && method === "POST") {
        return send(200, app.resolveProposal(req, match[1], match[2] === "accept"));
      }
      if (method === "GET" && path === "/v1/family/playlog") return send(200, app.playLog(req));
      if (method === "DELETE" && path === "/v1/family/playlog") return send(200, app.clearPlayLog(req));
      if (method === "POST" && path === "/v1/contrib/proposals") return send(201, app.submitProposal(req, await readJson(req)));
      if (method === "GET" && path === "/v1/contrib/me") return send(200, app.contributorState(req));
      if (method === "POST" && path === "/v1/device/playlog") return send(200, app.appendPlayLog(req, await readJson(req)));
      if (method === "POST" && path === "/v1/family/own-display") return send(200, app.registerOwnDisplay(req, await readJson(req)));
      if ((match = path.match(/^\/v1\/family\/claims\/([\w-]+)\/(approve|reject)$/)) && method === "POST") {
        return send(200, app.resolveClaim(req, match[1], match[2] === "approve"));
      }
      if ((match = path.match(/^\/v1\/family\/devices\/([\w-]+)$/)) && method === "DELETE") {
        return send(200, app.revokeDevice(req, match[1]));
      }
      if ((match = path.match(/^\/v1\/family\/devices\/([\w-]+)\/forget$/)) && method === "POST") {
        return send(200, app.forgetDevice(req, match[1]));
      }
      if ((match = path.match(/^\/v1\/family\/assets\/([0-9a-f]{64})$/)) && method === "PUT") {
        return send(201, app.putAsset(req, match[1], await readBody(req, MAX_ASSET_BYTES + 1)));
      }
      if ((match = path.match(/^\/v1\/assets\/([0-9a-f]{64})$/)) && method === "GET") {
        const asset = app.getAsset(req, match[1]);
        res.writeHead(200, { "content-type": asset.mime, "content-length": asset.bytes.length, "cache-control": "no-store" });
        return res.end(asset.bytes);
      }
      if (method === "GET" && path === "/v1/pairing/preview") return send(200, app.previewPairing(url.searchParams, client));
      if (method === "POST" && path === "/v1/pairing/claim") return send(201, app.claimPairing(await readJson(req), client));
      if ((match = path.match(/^\/v1\/pairing\/claims\/([\w-]+)$/)) && method === "GET") {
        return send(200, app.claimStatus(match[1], url.searchParams));
      }
      if (method === "GET" && path === "/v1/device/sync") return send(200, await app.displaySync(req, url.searchParams));
      if (method === "POST" && path === "/v1/device/receipt") return send(200, app.receipt(req, await readJson(req)));
      if (method === "POST" && path === "/v1/device/wipe-confirm") return send(200, app.confirmWipe(req));
      throw new HttpError(404, "not_found");
    } catch (error) {
      if (error instanceof HttpError) return send(error.status, { error: error.code, ...error.extra });
      console.error(error);
      return send(500, { error: "internal" });
    }
  };
}
