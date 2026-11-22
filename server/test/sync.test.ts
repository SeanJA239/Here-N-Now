import { createHash, randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHandler, HereNowServer, PAIRING_TTL_MS } from "../src/app.ts";

let clock = Date.parse("2026-11-22T08:00:00Z");
let app: HereNowServer;
let server: Server;
let base: string;
let dir: string;

before(async () => {
  dir = mkdtempSync(join(tmpdir(), "here-now-test-"));
  app = new HereNowServer({ dataDir: dir, now: () => clock });
  server = createServer(createHandler(app));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(() => {
  server.close();
  app.close();
  rmSync(dir, { recursive: true, force: true });
});

beforeEach(() => {
  clock += 60 * 60 * 1000;
});

async function call(method: string, path: string, { token, body }: { token?: string; body?: unknown } = {}) {
  const res = await fetch(base + path, {
    method,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: (await res.json()) as any };
}

const secret = () => randomBytes(24).toString("base64url");

async function newFamily(name = "妈妈的家") {
  const res = await call("POST", "/v1/families", {
    body: { familyName: name, installationId: `phone-${secret()}`, deviceName: "照护者的 iPhone" },
  });
  assert.equal(res.status, 201);
  return res.json as { familyId: string; deviceId: string; token: string; recoveryKey: string };
}

async function pairDisplay(caregiverToken: string, installationId = `ipad-${secret()}`) {
  const code = (await call("POST", "/v1/family/pairing-codes", { token: caregiverToken })).json.code;
  const claimSecret = secret();
  const claim = await call("POST", "/v1/pairing/claim", {
    body: { code, installationId, deviceName: "客厅 iPad", claimSecret },
  });
  assert.equal(claim.status, 201);
  await call("POST", `/v1/family/claims/${claim.json.claimId}/approve`, { token: caregiverToken });
  const status = await call("GET", `/v1/pairing/claims/${claim.json.claimId}?secret=${claimSecret}`);
  assert.equal(status.json.state, "approved");
  return { token: status.json.token as string, deviceId: status.json.deviceId as string, installationId };
}

describe("pairing (F02)", () => {
  it("rejects wrong, expired, and consumed codes", async () => {
    const family = await newFamily();
    const wrong = await call("POST", "/v1/pairing/claim", {
      body: { code: "AAAA-BBBB", installationId: "x", deviceName: "iPad", claimSecret: secret() },
    });
    assert.equal(wrong.status, 404);
    assert.equal(wrong.json.error, "pairing_code_invalid");

    const expired = (await call("POST", "/v1/family/pairing-codes", { token: family.token })).json.code;
    clock += PAIRING_TTL_MS + 1;
    const expiredClaim = await call("POST", "/v1/pairing/claim", {
      body: { code: expired, installationId: "x", deviceName: "iPad", claimSecret: secret() },
    });
    assert.equal(expiredClaim.status, 410);
    assert.equal(expiredClaim.json.error, "pairing_code_expired");

    const code = (await call("POST", "/v1/family/pairing-codes", { token: family.token })).json.code;
    const first = await call("POST", "/v1/pairing/claim", {
      body: { code, installationId: "ipad-1", deviceName: "iPad", claimSecret: secret() },
    });
    assert.equal(first.status, 201);
    const second = await call("POST", "/v1/pairing/claim", {
      body: { code, installationId: "ipad-2", deviceName: "Other iPad", claimSecret: secret() },
    });
    assert.equal(second.status, 409);
    assert.equal(second.json.error, "pairing_code_consumed");
  });

  it("does not hand out a device before the caregiver approves, and shows both sides the same family", async () => {
    const family = await newFamily("王家");
    const code = (await call("POST", "/v1/family/pairing-codes", { token: family.token })).json.code;
    const preview = await call("GET", `/v1/pairing/preview?code=${code}`);
    assert.equal(preview.json.familyName, "王家");
    assert.equal(preview.json.initiatedBy, "照护者的 iPhone");
    const claimSecret = secret();
    const claim = await call("POST", "/v1/pairing/claim", {
      body: { code, installationId: "ipad-a", deviceName: "客厅 iPad", claimSecret },
    });
    const pending = await call("GET", `/v1/pairing/claims/${claim.json.claimId}?secret=${claimSecret}`);
    assert.equal(pending.json.state, "pending");
    assert.equal(pending.json.token, undefined);
    const state = await call("GET", "/v1/family", { token: family.token });
    assert.deepEqual(
      state.json.pendingClaims.map((c: any) => c.deviceName),
      ["客厅 iPad"],
    );
    const wrongSecret = await call("GET", `/v1/pairing/claims/${claim.json.claimId}?secret=${secret()}`);
    assert.equal(wrongSecret.status, 404);
  });

  it("retried claims and re-pairing the same installation keep a single binding", async () => {
    const family = await newFamily();
    const code = (await call("POST", "/v1/family/pairing-codes", { token: family.token })).json.code;
    const claimSecret = secret();
    const body = { code, installationId: "ipad-same", deviceName: "客厅 iPad", claimSecret };
    const a = await call("POST", "/v1/pairing/claim", { body });
    const b = await call("POST", "/v1/pairing/claim", { body });
    assert.equal(b.status, 201);
    assert.equal(a.json.claimId, b.json.claimId);
    await call("POST", `/v1/family/claims/${a.json.claimId}/approve`, { token: family.token });
    await call("POST", `/v1/family/claims/${a.json.claimId}/approve`, { token: family.token });
    await pairDisplay(family.token, "ipad-same");
    const devices = (await call("GET", "/v1/family", { token: family.token })).json.devices;
    assert.equal(devices.filter((d: any) => d.role === "display").length, 1);
  });

  it("keeps families apart", async () => {
    const one = await newFamily("一家");
    const two = await newFamily("二家");
    const bytes = Buffer.from("photo-of-one");
    const sha = createHash("sha256").update(bytes).digest("hex");
    const put = await fetch(`${base}/v1/family/assets/${sha}`, {
      method: "PUT",
      headers: { authorization: `Bearer ${one.token}`, "content-type": "image/jpeg" },
      body: bytes,
    });
    assert.equal(put.status, 201);
    const display2 = await pairDisplay(two.token);
    const stolen = await fetch(`${base}/v1/assets/${sha}`, { headers: { authorization: `Bearer ${display2.token}` } });
    assert.equal(stolen.status, 404);
    const display1 = await pairDisplay(one.token);
    const own = await fetch(`${base}/v1/assets/${sha}`, { headers: { authorization: `Bearer ${display1.token}` } });
    assert.equal(own.status, 200);
    const asCaregiver = await call("GET", "/v1/family", { token: display1.token });
    assert.equal(asCaregiver.status, 403);
  });
});

describe("publish and sync (F09)", () => {
  it("applies a retried publish once and rejects stale bases", async () => {
    const family = await newFamily();
    const publish = { baseVersion: 0, publishId: "p-1", snapshot: { events: [{ id: "e1" }], assetRefs: [] } };
    const first = await call("POST", "/v1/family/publish", { token: family.token, body: publish });
    const retry = await call("POST", "/v1/family/publish", { token: family.token, body: publish });
    assert.equal(first.json.version, 1);
    assert.equal(retry.json.version, 1);
    assert.equal(retry.json.duplicate, true);

    const stale = await call("POST", "/v1/family/publish", {
      token: family.token,
      body: { baseVersion: 0, publishId: "p-2", snapshot: { events: [], assetRefs: [] } },
    });
    assert.equal(stale.status, 409);
    assert.equal(stale.json.currentVersion, 1);
    assert.deepEqual(stale.json.snapshot.events, [{ id: "e1" }]);
  });

  it("refuses a version whose assets were not uploaded, keeping the old version", async () => {
    const family = await newFamily();
    await call("POST", "/v1/family/publish", {
      token: family.token,
      body: { baseVersion: 0, publishId: "ok", snapshot: { text: "old", assetRefs: [] } },
    });
    const res = await call("POST", "/v1/family/publish", {
      token: family.token,
      body: { baseVersion: 1, publishId: "broken", snapshot: { text: "new", assetRefs: ["a".repeat(64)] } },
    });
    assert.equal(res.status, 422);
    assert.deepEqual(res.json.missingAssets, ["a".repeat(64)]);
    const display = await pairDisplay(family.token);
    const sync = await call("GET", "/v1/device/sync", { token: display.token });
    assert.equal(sync.json.version, 1);
    assert.equal(sync.json.snapshot.text, "old");
  });

  it("reports applied only after the display device sends its receipt", async () => {
    const family = await newFamily();
    const display = await pairDisplay(family.token);
    await call("POST", "/v1/family/publish", {
      token: family.token,
      body: { baseVersion: 0, publishId: "v1", snapshot: { assetRefs: [] } },
    });
    let device = (await call("GET", "/v1/family", { token: family.token })).json.devices.find(
      (d: any) => d.id === display.deviceId,
    );
    assert.equal(device.appliedVersion, null);
    await call("POST", "/v1/device/receipt", { token: display.token, body: { appliedVersion: 1, report: { audioRoute: "扬声器" } } });
    device = (await call("GET", "/v1/family", { token: family.token })).json.devices.find((d: any) => d.id === display.deviceId);
    assert.equal(device.appliedVersion, 1);
    assert.equal(device.report.audioRoute, "扬声器");
  });

  it("does not wake waiting clients when a receipt only renews volatile readings", async () => {
    const family = await newFamily();
    const display = await pairDisplay(family.token);
    const report = { audioRoute: "扬声器", deviceTime: 1, leaseExpiresAt: 2 };
    await call("POST", "/v1/device/receipt", { token: display.token, body: { appliedVersion: 0, report } });
    const before = (await call("GET", "/v1/family", { token: family.token })).json.rev;
    await call("POST", "/v1/device/receipt", {
      token: display.token,
      body: { appliedVersion: 0, report: { ...report, deviceTime: 99, leaseExpiresAt: 100 } },
    });
    assert.equal((await call("GET", "/v1/family", { token: family.token })).json.rev, before);
    await call("POST", "/v1/device/receipt", {
      token: display.token,
      body: { appliedVersion: 0, report: { ...report, audioRoute: "蓝牙：耳机" } },
    });
    assert.equal((await call("GET", "/v1/family", { token: family.token })).json.rev, before + 1);
  });

  it("wakes a waiting display as soon as a new version is published", async () => {
    const family = await newFamily();
    const display = await pairDisplay(family.token);
    const first = await call("GET", "/v1/device/sync", { token: display.token });
    const started = Date.now();
    const waiting = call("GET", `/v1/device/sync?knownRev=${first.json.rev}&knownVersion=0&wait=20`, { token: display.token });
    await new Promise((r) => setTimeout(r, 100));
    await call("POST", "/v1/family/publish", {
      token: family.token,
      body: { baseVersion: 0, publishId: "wake", snapshot: { hello: 1, assetRefs: [] } },
    });
    const woke = await waiting;
    assert.ok(Date.now() - started < 5000);
    assert.equal(woke.json.version, 1);
    assert.equal(woke.json.snapshot.hello, 1);
  });
});

describe("revocation and deletion (F13, F14)", () => {
  it("separates access revoked from data wiped", async () => {
    const family = await newFamily();
    const display = await pairDisplay(family.token);
    await call("DELETE", `/v1/family/devices/${display.deviceId}`, { token: family.token });
    let device = (await call("GET", "/v1/family", { token: family.token })).json.devices.find(
      (d: any) => d.id === display.deviceId,
    );
    assert.equal(device.wipeState, "pending");
    const sync = await call("GET", "/v1/device/sync", { token: display.token });
    assert.equal(sync.json.status, "revoked");
    assert.equal(sync.json.snapshot, undefined);
    const asset = await call("POST", "/v1/device/receipt", { token: display.token, body: { appliedVersion: 3 } });
    assert.equal(asset.status, 410);
    await call("POST", "/v1/device/wipe-confirm", { token: display.token });
    device = (await call("GET", "/v1/family", { token: family.token })).json.devices.find((d: any) => d.id === display.deviceId);
    assert.equal(device.wipeState, "confirmed");
  });

  it("deleting a family leaves offline devices marked pending instead of claiming they are wiped", async () => {
    const family = await newFamily();
    const display = await pairDisplay(family.token);
    const deleted = await call("DELETE", "/v1/family", { token: family.token });
    assert.equal(deleted.status, 200);
    const ipad = deleted.json.devices.find((d: any) => d.id === display.deviceId);
    assert.equal(ipad.wipeState, "pending");
    const sync = await call("GET", "/v1/device/sync", { token: display.token });
    assert.equal(sync.json.status, "family_deleted");
    await call("POST", "/v1/device/wipe-confirm", { token: display.token });
    const status = await call("GET", "/v1/family/deletion", { token: family.token });
    assert.equal(status.json.devices.find((d: any) => d.id === display.deviceId).wipeState, "confirmed");
    const again = await call("GET", "/v1/family", { token: family.token });
    assert.equal(again.status, 410);
  });

  it("recovery issues a new caregiver credential and retires the old one", async () => {
    const family = await newFamily();
    const recovered = await call("POST", "/v1/recover", {
      body: { recoveryKey: family.recoveryKey.toLowerCase(), installationId: "new-phone", deviceName: "新 iPhone" },
    });
    assert.equal(recovered.status, 200);
    assert.equal(recovered.json.familyId, family.familyId);
    assert.notEqual(recovered.json.recoveryKey, family.recoveryKey);
    const old = await call("GET", "/v1/family", { token: family.token });
    assert.equal(old.status, 410);
    const reuse = await call("POST", "/v1/recover", {
      body: { recoveryKey: family.recoveryKey, installationId: "thief", deviceName: "x" },
    });
    assert.equal(reuse.status, 404);
  });
});
