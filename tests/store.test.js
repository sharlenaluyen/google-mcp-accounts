import test from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import os from "os";
import path from "path";
import { spawn } from "child_process";
import { fileURLToPath } from "url";

// store.js computes CONFIG_DIR from GOOGLE_MCP_DIR at import time, so point
// it at a throwaway temp directory before importing - this keeps the test
// from ever touching the real ~/.google-mcp on the machine running it.
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "gmcp-test-"));
process.env.GOOGLE_MCP_DIR = path.join(tmpDir, "config");

const store = await import("../store.js");

test("CONFIG_DIR comes from GOOGLE_MCP_DIR", () => {
  assert.equal(store.CONFIG_DIR, path.join(tmpDir, "config"));
  assert.equal(store.ACCOUNTS_PATH, path.join(tmpDir, "config", "accounts.json"));
});

test("upsertAccount persists an account and loadAccounts reads it back", async () => {
  await store.upsertAccount("alias1", { email: "a@example.com", refresh_token: "rt1" });
  const accounts = store.loadAccounts();
  assert.equal(accounts.alias1.email, "a@example.com");
  assert.equal(accounts.alias1.refresh_token, "rt1");
});

test("accounts.json is written with owner-only permissions, in an owner-only folder", async () => {
  assert.equal(fs.statSync(store.ACCOUNTS_PATH).mode & 0o777, 0o600);
  assert.equal(fs.statSync(store.CONFIG_DIR).mode & 0o777, 0o700);
});

test("concurrent upserts are serialized, not lost", async () => {
  await Promise.all([
    store.upsertAccount("a", { email: "1@x.com", refresh_token: "r1" }),
    store.upsertAccount("b", { email: "2@x.com", refresh_token: "r2" }),
    store.upsertAccount("c", { email: "3@x.com", refresh_token: "r3" }),
  ]);
  const accounts = store.loadAccounts();
  assert.equal(accounts.a.email, "1@x.com");
  assert.equal(accounts.b.email, "2@x.com");
  assert.equal(accounts.c.email, "3@x.com");
});

test("removeAccount deletes only the named alias", async () => {
  await store.removeAccount("alias1");
  const accounts = store.loadAccounts();
  assert.equal(accounts.alias1, undefined);
  assert.equal(accounts.a.email, "1@x.com"); // untouched
});

test("writes never leave a stray .tmp file behind", () => {
  const dir = fs.readdirSync(store.CONFIG_DIR);
  assert.ok(!dir.some((f) => f.endsWith(".tmp")));
});

test("connecting an already-connected email under a new alias adds a nickname, not a second entry", async () => {
  await store.upsertAccount("main", { email: "same@x.com", refresh_token: "old" });
  const saved = await store.upsertAccount("other", { email: "same@x.com", refresh_token: "new" });
  const accounts = store.loadAccounts();
  assert.equal(saved.alias, "main");
  assert.equal(accounts.other, undefined);
  assert.deepEqual(accounts.main.nicknames, ["other"]);
  assert.equal(accounts.main.refresh_token, "new"); // one token, the freshest one
});

test("re-authorizing via a nickname refreshes the main entry", async () => {
  await store.upsertAccount("other", { email: "same@x.com", refresh_token: "newer" });
  const accounts = store.loadAccounts();
  assert.equal(accounts.other, undefined);
  assert.equal(accounts.main.refresh_token, "newer");
  assert.deepEqual(accounts.main.nicknames, ["other"]);
});

test("re-authorizing overwrites the token and granted scopes", async () => {
  await store.upsertAccount("main", { email: "same@x.com", refresh_token: "r-a", scopes: ["s1"] });
  await store.upsertAccount("main", { email: "same@x.com", refresh_token: "r-b", scopes: ["s1", "s2"] });
  const { main } = store.loadAccounts();
  assert.equal(main.refresh_token, "r-b");
  assert.deepEqual(main.scopes, ["s1", "s2"]);
});

test("addNickname rejects a name already in use, and resolveAlias follows nicknames", async () => {
  await store.addNickname("main", "m");
  await assert.rejects(store.addNickname("a", "m"), /already used by account "main"/);
  await assert.rejects(store.addNickname("a", "main"), /already used/);
  const accounts = store.loadAccounts();
  assert.equal(store.resolveAlias(accounts, "m"), "main");
  assert.equal(store.resolveAlias(accounts, "main"), "main");
  assert.equal(store.resolveAlias(accounts, "nope"), undefined);
});

test("removeAccount refuses a nickname; removeNickname keeps the account", async () => {
  await assert.rejects(store.removeAccount("m"), /is a nickname of "main"/);
  await store.removeNickname("m");
  const accounts = store.loadAccounts();
  assert.deepEqual(accounts.main.nicknames, ["other"]);
  await assert.rejects(store.removeNickname("main"), /not a nickname/);
});

test("an alias can't be silently re-pointed at an account connected under another alias", async () => {
  await assert.rejects(
    store.upsertAccount("a", { email: "same@x.com", refresh_token: "x" }),
    /already connected/
  );
  assert.equal(store.loadAccounts().a.email, "1@x.com");
});

test("setAccountField saves and clears a per-account setting, and re-authorizing keeps it", async () => {
  await store.setAccountField("other", "default_from", '"Me" <me@custom.com>'); // via a nickname
  assert.equal(store.loadAccounts().main.default_from, '"Me" <me@custom.com>');
  await store.upsertAccount("main", { email: "same@x.com", refresh_token: "fresh" });
  assert.equal(store.loadAccounts().main.default_from, '"Me" <me@custom.com>');
  await store.setAccountField("main", "default_from", null);
  assert.equal(store.loadAccounts().main.default_from, undefined);
  await assert.rejects(store.setAccountField("nope", "default_from", "x@y.com"), /Unknown account alias/);
});

test("setAccountField refuses credential and identity fields", async () => {
  for (const field of ["refresh_token", "email", "nicknames", "scopes", "authorized_at"]) {
    await assert.rejects(store.setAccountField("main", field, "evil"), /re-running the auth CLI/);
  }
  assert.equal(store.loadAccounts().main.refresh_token, "fresh");
});

test("a failed write doesn't jam the queue for later writes", async () => {
  await assert.rejects(store.addNickname("nope", "zz"), /Unknown account alias/);
  await store.addNickname("main", "zz");
  assert.ok(store.loadAccounts().main.nicknames.includes("zz"));
});

test("loadCredentials explains where the OAuth client file belongs when it's missing", () => {
  assert.throws(
    () => store.loadCredentials(),
    new RegExp(store.CREDENTIALS_PATH.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
  );
});

test("loadCredentials reads a Desktop-app client file", () => {
  fs.writeFileSync(
    store.CREDENTIALS_PATH,
    JSON.stringify({
      installed: { client_id: "id", client_secret: "sec", redirect_uris: ["http://localhost"] },
    })
  );
  assert.deepEqual(store.loadCredentials(), {
    clientId: "id",
    clientSecret: "sec",
    redirectUri: "http://localhost",
  });
});

// --- Cross-process lock ----------------------------------------------------

const HELPER = fileURLToPath(new URL("./helpers/write-fields.js", import.meta.url));

function runChild(args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [HELPER, ...args], {
      env: { ...process.env, ...env },
      stdio: "pipe",
    });
    let stderr = "";
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`child exited ${code}: ${stderr}`))
    );
  });
}

function exitedPid() {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, ["-e", ""]);
    child.on("exit", () => resolve(child.pid));
  });
}

const writeLock = (lock) => fs.writeFileSync(store.LOCK_PATH, JSON.stringify(lock), { mode: 0o600 });

test("two separate processes writing at the same time don't lose each other's updates", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gmcp-lock-"));
  fs.writeFileSync(
    path.join(dir, "accounts.json"),
    JSON.stringify({ main: { email: "m@x.com", refresh_token: "rt", nicknames: [] } })
  );
  const PER_CHILD = 40;
  const startAt = String(Date.now() + 300); // both start writing at the same moment
  await Promise.all([
    runChild(["a", String(PER_CHILD), startAt], { GOOGLE_MCP_DIR: dir }),
    runChild(["b", String(PER_CHILD), startAt], { GOOGLE_MCP_DIR: dir }),
  ]);
  const main = JSON.parse(fs.readFileSync(path.join(dir, "accounts.json"), "utf8")).main;
  for (const id of ["a", "b"]) {
    for (let i = 0; i < PER_CHILD; i++) assert.equal(main[`w${id}_${i}`], i, `lost w${id}_${i}`);
  }
  assert.equal(main.refresh_token, "rt");
  assert.deepEqual(fs.readdirSync(dir), ["accounts.json"]); // no lock, temp, or stale files left behind
});

test("a lock left by a dead process is cleared instead of blocking writes", async () => {
  writeLock({ pid: await exitedPid(), host: os.hostname(), time: Date.now(), token: "dead" });
  await store.setAccountField("main", "after_dead_lock", "ok");
  assert.equal(store.loadAccounts().main.after_dead_lock, "ok");
  assert.ok(!fs.existsSync(store.LOCK_PATH));
});

test("a lock older than the stale limit is cleared even if its pid is alive (pid reuse)", async () => {
  writeLock({ pid: process.pid, host: os.hostname(), time: Date.now() - 60_000, token: "old" });
  await store.setAccountField("main", "after_old_lock", "ok");
  assert.equal(store.loadAccounts().main.after_old_lock, "ok");
});

test("a half-written lock file is cleared once it's old", async () => {
  fs.writeFileSync(store.LOCK_PATH, "");
  const old = new Date(Date.now() - 60_000);
  fs.utimesSync(store.LOCK_PATH, old, old);
  await store.setAccountField("main", "after_empty_lock", "ok");
  assert.equal(store.loadAccounts().main.after_empty_lock, "ok");
});

test("a fresh lock held by a live process makes writes wait until it's released", async () => {
  writeLock({ pid: process.pid, host: os.hostname(), time: Date.now(), token: "live" });
  const pending = store.setAccountField("main", "after_live_lock", "ok");
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(store.loadAccounts().main.after_live_lock, undefined); // still waiting
  fs.rmSync(store.LOCK_PATH);
  await pending;
  assert.equal(store.loadAccounts().main.after_live_lock, "ok");
});

test("saveAccounts isn't exported, so nothing can write accounts.json without the lock", () => {
  assert.equal(store.saveAccounts, undefined);
});
