import crypto from "crypto";
import fs from "fs";
import path from "path";
import os from "os";

// Where everything lives: ~/.google-mcp/ (override with GOOGLE_MCP_DIR).
// Every Google MCP server (Gmail, Calendar, Drive, Docs/Sheets/Slides) reads
// the same accounts.json, so each Google account is authorized exactly once.
export const CONFIG_DIR = process.env.GOOGLE_MCP_DIR
  ? path.resolve(process.env.GOOGLE_MCP_DIR)
  : path.join(os.homedir(), ".google-mcp");
export const CREDENTIALS_PATH = path.join(CONFIG_DIR, "credentials.json"); // Google OAuth client (you provide this)
export const ACCOUNTS_PATH = path.join(CONFIG_DIR, "accounts.json"); // alias -> tokens + email + nicknames, written by auth.js

// Fields only the auth CLI may set. setAccountField refuses them, so a
// server-side settings tool can never swap a token or re-point an alias.
const PROTECTED_FIELDS = new Set(["email", "refresh_token", "nicknames", "scopes", "authorized_at"]);

export function ensureConfigDir() {
  if (!fs.existsSync(CONFIG_DIR)) {
    fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  }
}

export function loadCredentials() {
  if (!fs.existsSync(CREDENTIALS_PATH)) {
    throw new Error(
      `No Google OAuth client credentials found at ${CREDENTIALS_PATH}.\n` +
        `Download the OAuth client JSON from Google Cloud Console (APIs & Services -> Credentials)\n` +
        `and save it at that exact path, then re-run.`
    );
  }
  const raw = JSON.parse(fs.readFileSync(CREDENTIALS_PATH, "utf8"));
  const key = raw.installed || raw.web;
  if (!key) {
    throw new Error(
      `credentials.json doesn't look like a Google OAuth client file (expected an "installed" or "web" key).`
    );
  }
  return {
    clientId: key.client_id,
    clientSecret: key.client_secret,
    redirectUri: (key.redirect_uris && key.redirect_uris[0]) || "http://localhost:53682/oauth2callback",
  };
}

export function loadAccounts() {
  ensureConfigDir();
  if (!fs.existsSync(ACCOUNTS_PATH)) return {};
  return JSON.parse(fs.readFileSync(ACCOUNTS_PATH, "utf8"));
}

// Not exported: every write goes through serialized() below, so nothing can
// save accounts.json without holding the lock.
function saveAccounts(accounts) {
  ensureConfigDir();
  // Atomic write: write to a temp file in the same directory, then rename.
  // Rename is atomic on the same filesystem, so a crash or a concurrent
  // reader never observes a half-written accounts.json.
  const tmpPath = `${ACCOUNTS_PATH}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmpPath, JSON.stringify(accounts, null, 2), { mode: 0o600 });
  fs.renameSync(tmpPath, ACCOUNTS_PATH);
}

// --- Cross-process lock ----------------------------------------------------
// Several processes can write accounts.json: the auth CLI, the Gmail server
// (set_default_from), or two copies of a server started by different clients.
// Without a lock, two read-modify-write cycles that overlap would each save
// their own copy and one update would be lost. The lock is a file created
// with O_EXCL ("wx"), which the OS guarantees only one process can win.
export const LOCK_PATH = `${ACCOUNTS_PATH}.lock`;
const LOCK_TIMEOUT_MS = 10_000; // a write holds the lock for milliseconds; 10s means something is stuck
const LOCK_STALE_MS = 30_000; // older than this, the holder is treated as gone even if its pid is reused
const LOCK_RETRY_MS = 25;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// The lock's contents, or for a lock that exists but can't be parsed (its
// creator died between creating and writing it), just its age from mtime.
function readLock(lockPath) {
  try {
    return JSON.parse(fs.readFileSync(lockPath, "utf8"));
  } catch {
    try {
      return { time: fs.statSync(lockPath).mtimeMs };
    } catch {
      return null; // gone
    }
  }
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0); // signal 0: existence check only
    return true;
  } catch (err) {
    return err.code === "EPERM"; // exists but belongs to another user
  }
}

// A lock is stale when its holder is a dead process on this machine, or when
// it's older than LOCK_STALE_MS (covers another host on a shared folder, and a
// pid reused by an unrelated process).
function isStale(lock, now = Date.now()) {
  if (!lock || typeof lock.time !== "number") return false;
  if (now - lock.time > LOCK_STALE_MS) return true;
  return lock.host === os.hostname() && Number.isInteger(lock.pid) && !processIsAlive(lock.pid);
}

// Removes a stale lock without risking someone else's fresh one: the lock is
// renamed away first (only one waiter can win that rename), and if what was
// grabbed turns out not to be the stale lock that was inspected, it's put back.
function breakStaleLock(stale) {
  const grabbed = `${LOCK_PATH}.stale.${process.pid}.${crypto.randomUUID()}`;
  try {
    fs.renameSync(LOCK_PATH, grabbed);
  } catch {
    return; // another waiter already broke it
  }
  if (readLock(grabbed)?.token !== stale.token) {
    try {
      fs.linkSync(grabbed, LOCK_PATH); // no-clobber put-back
    } catch {
      // A newer lock already exists; the one grabbed was released meanwhile.
    }
  }
  fs.rmSync(grabbed, { force: true });
}

async function acquireLock() {
  ensureConfigDir();
  const lock = { pid: process.pid, host: os.hostname(), time: Date.now(), token: crypto.randomUUID() };
  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  for (;;) {
    try {
      const fd = fs.openSync(LOCK_PATH, "wx", 0o600);
      fs.writeSync(fd, JSON.stringify(lock));
      fs.closeSync(fd);
      return lock;
    } catch (err) {
      if (err.code !== "EEXIST") throw err;
    }
    const holder = readLock(LOCK_PATH);
    if (isStale(holder)) {
      breakStaleLock(holder);
      continue;
    }
    if (Date.now() > deadline) {
      throw new Error(
        `Timed out waiting for ${LOCK_PATH}` +
          (holder ? ` (held by process ${holder.pid} since ${new Date(holder.time).toISOString()})` : "") +
          `. If no google-mcp auth command or server is running, delete that file and try again.`
      );
    }
    await sleep(LOCK_RETRY_MS + Math.random() * LOCK_RETRY_MS);
  }
}

function releaseLock(lock) {
  // Only remove the lock if it's still ours; if it was broken as stale and
  // someone else took it, deleting it would let a third process in.
  if (readLock(LOCK_PATH)?.token === lock.token) fs.rmSync(LOCK_PATH, { force: true });
}

// Serializes read-modify-write cycles: an in-process queue keeps this
// process's own writes in order, and the lock file keeps other processes out
// while each cycle reads, changes, and saves accounts.json. Readers don't
// take the lock; the atomic rename means they always see a whole file.
let writeQueue = Promise.resolve();
function serialized(fn) {
  const result = writeQueue.then(async () => {
    const lock = await acquireLock();
    try {
      return fn();
    } finally {
      releaseLock(lock);
    }
  });
  // Keep the queue alive even if this write fails, so later writes still run.
  writeQueue = result.catch(() => {});
  return result;
}

// Each entry in accounts.json is keyed by its main alias and may carry a
// `nicknames` list of extra names that point at the same account (and the
// same refresh token). Returns the main alias that `name` refers to, or
// undefined if nothing matches.
export function resolveAlias(accounts, name) {
  if (Object.hasOwn(accounts, name)) return name;
  return Object.keys(accounts).find((alias) => (accounts[alias].nicknames || []).includes(name));
}

// Connect or re-authorize. If `data.email` is already connected under a
// different alias, that entry gets the fresh token and `alias` becomes one of
// its nicknames, so one Google account never ends up with two entries.
export function upsertAccount(alias, data) {
  return serialized(() => {
    const accounts = loadAccounts();
    const existing = resolveAlias(accounts, alias);
    const sameEmail = data.email && Object.keys(accounts).find((a) => accounts[a].email === data.email);

    if (sameEmail && sameEmail !== existing) {
      if (existing === alias) {
        throw new Error(
          `"${alias}" is already connected to ${accounts[alias].email}, and ${data.email} is already connected as "${sameEmail}". ` +
            `Remove "${alias}" first, or add it as a nickname of "${sameEmail}".`
        );
      }
      if (existing) dropNickname(accounts, existing, alias); // nickname moving to a different account
      const target = accounts[sameEmail];
      accounts[sameEmail] = { ...target, ...data, nicknames: [...(target.nicknames || []), alias] };
      saveAccounts(accounts);
      return { alias: sameEmail, ...accounts[sameEmail] };
    }

    const key = existing || alias;
    accounts[key] = { nicknames: [], ...accounts[key], ...data };
    saveAccounts(accounts);
    return { alias: key, ...accounts[key] };
  });
}

function dropNickname(accounts, alias, nickname) {
  accounts[alias].nicknames = (accounts[alias].nicknames || []).filter((n) => n !== nickname);
}

export function addNickname(name, nickname) {
  return serialized(() => {
    const accounts = loadAccounts();
    const alias = resolveAlias(accounts, name);
    if (!alias) throw new Error(`Unknown account alias "${name}".`);
    const taken = resolveAlias(accounts, nickname);
    if (taken) throw new Error(`"${nickname}" is already used by account "${taken}".`);
    accounts[alias].nicknames = [...(accounts[alias].nicknames || []), nickname];
    saveAccounts(accounts);
    return alias;
  });
}

export function removeNickname(nickname) {
  return serialized(() => {
    const accounts = loadAccounts();
    const alias = resolveAlias(accounts, nickname);
    if (!alias || alias === nickname) throw new Error(`"${nickname}" is not a nickname.`);
    dropNickname(accounts, alias, nickname);
    saveAccounts(accounts);
    return alias;
  });
}

// Saves (or with `value` = null, clears) one per-account setting, such as
// Gmail's default_from. Re-authorizing keeps it, since upsertAccount merges
// into the entry. Credentials and identity fields are refused - only the
// auth CLI (via upsertAccount) may change those.
export function setAccountField(name, field, value) {
  return serialized(() => {
    if (PROTECTED_FIELDS.has(field)) {
      throw new Error(`"${field}" can only be changed by re-running the auth CLI.`);
    }
    const accounts = loadAccounts();
    const alias = resolveAlias(accounts, name);
    if (!alias) throw new Error(`Unknown account alias "${name}".`);
    if (value != null) accounts[alias][field] = value;
    else delete accounts[alias][field];
    saveAccounts(accounts);
    return alias;
  });
}

// Removes the whole account (token and all nicknames). Refuses a nickname so
// a typo can't disconnect an account you meant to keep.
export function removeAccount(alias) {
  return serialized(() => {
    const accounts = loadAccounts();
    const owner = resolveAlias(accounts, alias);
    if (owner && owner !== alias) {
      throw new Error(
        `"${alias}" is a nickname of "${owner}". Use --unnick ${alias} to remove just the nickname.`
      );
    }
    delete accounts[alias];
    saveAccounts(accounts);
  });
}
