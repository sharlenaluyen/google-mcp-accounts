import test from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import os from "os";
import path from "path";

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "gmcp-test-accounts-"));
process.env.GOOGLE_MCP_DIR = path.join(tmpDir, "config");

const store = await import("../store.js");
const { getConnectedAliases, getAccountInfo, missingScopes, hasScope, createAuthClient } =
  await import("../accounts.js");
const { PRODUCT_SCOPES } = await import("../scopes.js");

fs.mkdirSync(store.CONFIG_DIR, { recursive: true });
fs.writeFileSync(
  store.CREDENTIALS_PATH,
  JSON.stringify({
    installed: { client_id: "cid", client_secret: "csec", redirect_uris: ["http://localhost"] },
  })
);
await store.upsertAccount("main", { email: "same@x.com", refresh_token: "rt", scopes: PRODUCT_SCOPES.gmail });
await store.upsertAccount("other", {
  email: "same@x.com",
  refresh_token: "rt2",
  scopes: PRODUCT_SCOPES.gmail,
});
await store.upsertAccount("legacy", { email: "old@x.com", refresh_token: "rt3" }); // no scopes recorded

// Stands in for google.auth.OAuth2 so the test makes no network calls.
class FakeOAuth2 {
  constructor(id, secret, redirect) {
    Object.assign(this, { id, secret, redirect });
  }
  setCredentials(creds) {
    this.creds = creds;
  }
}

test("getAccountInfo resolves nicknames and getConnectedAliases lists each account once", () => {
  const info = getAccountInfo("other");
  assert.equal(info.alias, "main");
  assert.equal(info.email, "same@x.com");
  const aliases = getConnectedAliases();
  assert.equal(aliases.filter((a) => a === "main").length, 1);
  assert.ok(!aliases.includes("other"));
  assert.throws(() => getAccountInfo("nope"), /Connected aliases: .*other/);
});

test("missingScopes lists what an account never granted; unknown scopes pass", () => {
  const info = getAccountInfo("main");
  assert.deepEqual(missingScopes(info, PRODUCT_SCOPES.gmail), []);
  assert.deepEqual(missingScopes(info, PRODUCT_SCOPES.calendar), PRODUCT_SCOPES.calendar);
  assert.deepEqual(missingScopes(getAccountInfo("legacy"), PRODUCT_SCOPES.calendar), []);
  assert.ok(hasScope(info, PRODUCT_SCOPES.gmail[0]));
  assert.ok(!hasScope(getAccountInfo("legacy"), PRODUCT_SCOPES.gmail[0]));
});

test("createAuthClient builds a refreshing client from the stored token", () => {
  const client = createAuthClient("other", { OAuth2: FakeOAuth2, requiredScopes: PRODUCT_SCOPES.gmail });
  assert.equal(client.id, "cid");
  assert.equal(client.secret, "csec");
  assert.deepEqual(client.creds, { refresh_token: "rt2" });
});

test("createAuthClient refuses up front when a needed scope wasn't granted, naming the fix", () => {
  assert.throws(
    () => createAuthClient("main", { OAuth2: FakeOAuth2, requiredScopes: PRODUCT_SCOPES.drive }),
    /hasn't granted drive\.file\. Re-authorize it once with: node auth\.js main/
  );
});
