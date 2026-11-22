import { createHash, randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHandler, HereNowServer } from "../src/app.ts";

let clock = Date.parse("2026-11-22T08:00:00Z");
let app: HereNowServer;
let server: Server;
let base: string;
let dir: string;

before(async () => {
  dir = mkdtempSync(join(tmpdir(), "here-now-p1-"));
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

async function family() {
  return (await call("POST", "/v1/families", { body: { familyName: "王家", installationId: secret(), deviceName: "主要照护者" } })).json;
}

async function joinAs(caregiver: string, role: "display" | "contributor", name: string) {
  const code = (await call("POST", "/v1/family/pairing-codes", { token: caregiver, body: { role } })).json.code;
  const claimSecret = secret();
  const claim = (await call("POST", "/v1/pairing/claim", { body: { code, installationId: secret(), deviceName: name, claimSecret } })).json;
  assert.equal(claim.role, role);
  await call("POST", `/v1/family/claims/${claim.claimId}/approve`, { token: caregiver });
  return (await call("GET", `/v1/pairing/claims/${claim.claimId}?secret=${claimSecret}`)).json;
}

async function upload(token: string, text: string) {
  const bytes = Buffer.from(text);
  const sha = createHash("sha256").update(bytes).digest("hex");
  const res = await fetch(`${base}/v1/family/assets/${sha}`, {
    method: "PUT",
    headers: { authorization: `Bearer ${token}`, "content-type": "audio/mp4" },
    body: bytes,
  });
  return { status: res.status, sha };
}

describe("family contributors", () => {
  it("can only suggest: no family content, no publishing, no display sync", async () => {
    const f = await family();
    await call("POST", "/v1/family/publish", { token: f.token, body: { baseVersion: 0, publishId: "a", snapshot: { secret: "content", assetRefs: [] } } });
    const contributor = await joinAs(f.token, "contributor", "小雨的 iPhone");
    assert.equal(contributor.role, "contributor");
    for (const [method, path] of [["GET", "/v1/family"], ["GET", "/v1/device/sync"], ["POST", "/v1/family/publish"]] as const) {
      const res = await call(method, path, { token: contributor.token, body: method === "POST" ? { baseVersion: 1, publishId: "x", snapshot: {} } : undefined });
      assert.ok(res.status === 403, `${path} should be forbidden, got ${res.status}`);
    }
    const me = await call("GET", "/v1/contrib/me", { token: contributor.token });
    assert.equal(me.json.familyName, "王家");
    assert.equal(JSON.stringify(me.json).includes("content"), false);
  });

  it("delivers a recording suggestion to the caregiver, who decides", async () => {
    const f = await family();
    const contributor = await joinAs(f.token, "contributor", "小雨的 iPhone");
    const asset = await upload(contributor.token, "voice-of-xiaoyu");
    assert.equal(asset.status, 201);
    const submitted = await call("POST", "/v1/contrib/proposals", {
      token: contributor.token,
      body: { kind: "recording", payload: { speakerLabel: "小雨", note: "给妈妈的问候" }, assetRefs: [asset.sha] },
    });
    assert.equal(submitted.status, 201);
    const state = await call("GET", "/v1/family", { token: f.token });
    assert.equal(state.json.proposals.length, 1);
    assert.equal(state.json.proposals[0].deviceName, "小雨的 iPhone");
    const audio = await fetch(`${base}/v1/assets/${asset.sha}`, { headers: { authorization: `Bearer ${f.token}` } });
    assert.equal(audio.status, 200);

    clock += 2 * 86_400_000;
    await call("POST", "/v1/family/publish", { token: f.token, body: { baseVersion: 0, publishId: "gc", snapshot: { assetRefs: [] } } });
    const stillThere = await fetch(`${base}/v1/assets/${asset.sha}`, { headers: { authorization: `Bearer ${f.token}` } });
    assert.equal(stillThere.status, 200, "pending suggestions keep their audio through asset cleanup");

    const resolved = await call("POST", `/v1/family/proposals/${submitted.json.id}/accept`, { token: f.token });
    assert.equal(resolved.json.state, "accepted");
    const mine = await call("GET", "/v1/contrib/me", { token: contributor.token });
    assert.equal(mine.json.proposals[0].state, "accepted");
  });

  it("cannot fetch another member's assets", async () => {
    const f = await family();
    const a = await joinAs(f.token, "contributor", "A");
    const b = await joinAs(f.token, "contributor", "B");
    const asset = await upload(f.token, "caregiver-photo");
    await upload(a.token, "a-voice");
    const res = await fetch(`${base}/v1/assets/${asset.sha}`, { headers: { authorization: `Bearer ${b.token}` } });
    assert.equal(res.status, 404);
  });
});

describe("comfort command", () => {
  it("is stamped with server time and a new request id on every start", async () => {
    const f = await family();
    const first = await call("POST", "/v1/family/controls", { token: f.token, body: { comfortItemID: "song" } });
    clock += 1000;
    const second = await call("POST", "/v1/family/controls", { token: f.token, body: { comfortItemID: "song" } });
    assert.notEqual(first.json.controls.comfortRequestID, second.json.controls.comfortRequestID);
    assert.equal(second.json.controls.comfortRequestedAt, new Date(clock).toISOString().replace(".000Z", "Z"));
    const paused = await call("POST", "/v1/family/controls", { token: f.token, body: { soundPaused: true } });
    assert.equal(paused.json.controls.comfortRequestID, second.json.controls.comfortRequestID, "unrelated changes keep the request");
    const stop = await call("POST", "/v1/family/controls", { token: f.token, body: { comfortItemID: null } });
    assert.equal(stop.json.controls.comfortItemID, null);
  });
});

describe("play log", () => {
  it("keeps 7 days and can be cleared", async () => {
    const f = await family();
    const display = await joinAs(f.token, "display", "iPad");
    const iso = (ms: number) => new Date(ms).toISOString();
    await call("POST", "/v1/device/playlog", {
      token: display.token,
      body: {
        entries: [
          { at: iso(clock - 8 * 86_400_000), kind: "started", trigger: "button", source: "rec" },
          { at: iso(clock - 1000), kind: "started", trigger: "button", source: "rec" },
        ],
        coverage: [{ start: iso(clock - 3_600_000), end: iso(clock) }],
      },
    });
    const log = await call("GET", "/v1/family/playlog", { token: f.token });
    assert.equal(log.json.entries.length, 1);
    assert.equal(log.json.coverage.length, 1);
    await call("DELETE", "/v1/family/playlog", { token: f.token });
    assert.equal((await call("GET", "/v1/family/playlog", { token: f.token })).json.entries.length, 0);
  });
});
