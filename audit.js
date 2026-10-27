import fs from "fs";
import path from "path";
import { CONFIG_DIR, ensureConfigDir } from "./store.js";

export const AUDIT_LOG_PATH = path.join(CONFIG_DIR, "audit.log");

// Append-only JSONL log of every action with a side effect someone else could
// see (sends, shares, deletes, event invites, document edits), shared by all
// the Google MCP servers. Each line is one JSON object, so the file is
// append-safe (no read-modify-write race like accounts.json has) and easy to
// tail or grep:
//   tail -f ~/.google-mcp/audit.log
//   grep '"server":"multi-gdrive-mcp"' ~/.google-mcp/audit.log
//
// Deliberately never logs content (email bodies, document text, cell values)
// - just enough to answer "what did which server do, from which account, and
// when" after the fact.
export function logAuditEvent({ server, action, account, email, outcome, detail }) {
  ensureConfigDir();
  const line = {
    ts: new Date().toISOString(),
    server, // which MCP server did it, e.g. "multi-gmail-mcp"
    action, // the tool name, e.g. "send_email", "share_file", "create_event"
    account,
    email,
    outcome, // e.g. "dry_run" | "sent" | "shared" | "created" | "updated" | "deleted" | "error"
    detail, // small plain object: ids, recipients, titles - no bodies or file contents
  };
  try {
    // First write to this file in the process: make sure it's owner-only.
    const exists = fs.existsSync(AUDIT_LOG_PATH);
    fs.appendFileSync(AUDIT_LOG_PATH, JSON.stringify(line) + "\n", { mode: 0o600 });
    if (!exists) fs.chmodSync(AUDIT_LOG_PATH, 0o600);
  } catch {
    // Audit logging is best-effort - never let a logging failure block or
    // crash the actual action it's trying to record.
  }
}

// Binds the server name once, so each server's tool handlers can't forget it.
export function createAuditLogger(server) {
  return (event) => logAuditEvent({ ...event, server });
}
