import test from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import os from "os";
import path from "path";

// audit.js reads CONFIG_DIR from store.js, which is computed from
// GOOGLE_MCP_DIR at import time - isolate it the same way store.test.js does.
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "gmcp-test-audit-"));
process.env.GOOGLE_MCP_DIR = path.join(tmpDir, "config");

const { logAuditEvent, createAuditLogger, AUDIT_LOG_PATH } = await import("../audit.js");

function readLines() {
  return fs
    .readFileSync(AUDIT_LOG_PATH, "utf8")
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l));
}

test("logAuditEvent appends one JSON line per call, tagged with the server, never content", () => {
  logAuditEvent({
    server: "multi-gmail-mcp",
    action: "send_email",
    account: "work",
    email: "me@work.com",
    outcome: "sent",
    detail: { to: "x@y.com", subject: "Hi" },
  });
  logAuditEvent({
    server: "multi-gdrive-mcp",
    action: "share_file",
    account: "work",
    email: "me@work.com",
    outcome: "shared",
    detail: { file_id: "f1", grantee: "x@y.com", role: "reader" },
  });

  const lines = readLines();
  assert.equal(lines.length, 2);

  const [first, second] = lines;
  assert.equal(first.server, "multi-gmail-mcp");
  assert.equal(first.action, "send_email");
  assert.equal(first.outcome, "sent");
  assert.ok(!Number.isNaN(Date.parse(first.ts))); // ISO timestamp present
  assert.equal(first.detail.body, undefined); // never logs the body
  assert.equal(second.server, "multi-gdrive-mcp");
  assert.equal(second.action, "share_file");
});

test("createAuditLogger stamps every event with its server name, which callers can't override", () => {
  const log = createAuditLogger("multi-gcal-mcp");
  log({ server: "spoofed", action: "create_event", account: "p", email: "p@x.com", outcome: "dry_run" });
  const last = readLines().at(-1);
  assert.equal(last.server, "multi-gcal-mcp");
  assert.equal(last.action, "create_event");
  assert.equal(last.outcome, "dry_run");
});

test("audit.log is owner-only readable", () => {
  const stat = fs.statSync(AUDIT_LOG_PATH);
  assert.equal(stat.mode & 0o777, 0o600);
});

test("logAuditEvent never throws, even if it can't write", () => {
  fs.rmSync(AUDIT_LOG_PATH);
  fs.mkdirSync(AUDIT_LOG_PATH); // a directory where the log file should be: appends fail
  assert.doesNotThrow(() =>
    logAuditEvent({
      server: "x",
      action: "send_email",
      account: "x",
      email: "x@y.com",
      outcome: "sent",
      detail: {},
    })
  );
});
