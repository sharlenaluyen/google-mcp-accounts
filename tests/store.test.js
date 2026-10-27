import test from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import os from "os";
import path from "path";

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

test("saveAccounts never leaves a stray .tmp file behind", () => {
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
