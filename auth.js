#!/usr/bin/env node
// The only program that writes OAuth tokens to ~/.google-mcp/accounts.json.
// Every Google MCP server only reads that file.
//
// Usage:
//   node auth.js <alias>                       -> connect/re-auth one Google account under this alias
//   node auth.js <alias> --with-drive-readonly -> same, plus read access to your whole Drive (opt-in)
//   node auth.js --list                        -> list connected accounts and what each one granted
//   node auth.js --remove <alias>              -> disconnect an account
//   node auth.js --nick <alias> <nickname>     -> add another name for an account
//   node auth.js --unnick <nickname>           -> remove a nickname

import crypto from "crypto";
import http from "http";
import { URL } from "url";
import { OAuth2Client } from "google-auth-library";
import open from "open";
import {
  CONFIG_DIR,
  ACCOUNTS_PATH,
  loadCredentials,
  upsertAccount,
  loadAccounts,
  removeAccount,
  addNickname,
  removeNickname,
} from "./store.js";
import { REQUIRED_SCOPES, DRIVE_READONLY_SCOPE, scopesToRequest, shortScope } from "./scopes.js";

const NAME_PATTERN = /^[a-z0-9_-]+$/i;

function parseArgs() {
  const args = process.argv.slice(2);
  if (args[0] === "--list") return { cmd: "list" };
  if (args[0] === "--remove") return { cmd: "remove", alias: args[1] };
  if (args[0] === "--nick") return { cmd: "nick", alias: args[1], nickname: args[2] };
  if (args[0] === "--unnick") return { cmd: "unnick", nickname: args[1] };
  if (args[0] && !args[0].startsWith("--")) {
    return { cmd: "connect", alias: args[0], driveReadonly: args.includes("--with-drive-readonly") };
  }
  return { cmd: "help" };
}

async function connect(alias, driveReadonly) {
  if (!alias || !NAME_PATTERN.test(alias)) {
    console.error("Give this account a short alias, e.g.: node auth.js personal");
    process.exit(1);
  }

  const { clientId, clientSecret, redirectUri } = loadCredentials();
  const url = new URL(redirectUri);
  // Desktop-app clients list a bare "http://localhost"; Google accepts any loopback
  // port for them, so pin one we can listen on and send that same URI to Google.
  if (!url.port) url.port = "53682";
  const port = Number(url.port);

  const scopes = scopesToRequest({ driveReadonly });
  // Ties the browser redirect back to this run, so another local page can't
  // feed the callback a code for a different Google account.
  const state = crypto.randomBytes(16).toString("hex");
  const oauth2Client = new OAuth2Client(clientId, clientSecret, url.toString());
  const authUrl = oauth2Client.generateAuthUrl({
    access_type: "offline",
    prompt: "consent", // forces a refresh_token every time, important when re-connecting
    scope: scopes,
    state,
  });

  console.log(`\nConnecting Google account as alias "${alias}".`);
  console.log(`Requesting: ${scopes.map(shortScope).join(", ")}`);
  if (driveReadonly) console.log(`Includes drive.readonly: read access to every file in this Drive.`);
  console.log(`Opening your browser for Google sign-in...\n`);
  console.log(`If it doesn't open automatically, visit:\n${authUrl}\n`);

  const codePromise = waitForCode(port, url.pathname, state);
  open(authUrl).catch(() => {});
  const code = await codePromise.catch(fail);
  const { tokens } = await oauth2Client.getToken(code).catch(fail);
  if (!tokens.refresh_token) fail(new Error("Google didn't return a refresh token. Run the command again."));
  oauth2Client.setCredentials(tokens);

  // Google's consent screen lets people untick individual permissions, so
  // record what was actually granted rather than what was asked for.
  const granted = (tokens.scope || scopes.join(" ")).split(" ").filter(Boolean);
  const email = await lookupEmail(oauth2Client).catch(fail);

  const saved = await upsertAccount(alias, {
    email,
    refresh_token: tokens.refresh_token,
    scopes: granted,
    authorized_at: new Date().toISOString(),
    // access_token/expiry are re-fetched at runtime; we don't need to persist them.
  }).catch(fail);

  if (saved.alias !== alias) {
    console.log(
      `\n${email} was already connected as "${saved.alias}" - refreshed its token and added "${alias}" as a nickname.`
    );
  } else {
    console.log(`\nConnected: alias "${alias}" -> ${email}`);
  }
  const notGranted = scopes.filter((s) => !granted.includes(s));
  if (notGranted.length) {
    console.log(
      `Not granted (tools needing these will ask you to re-run this): ${notGranted.map(shortScope).join(", ")}`
    );
  }
  console.log(`Run "node auth.js --list" to see all connected accounts.\n`);
  process.exit(0);
}

// The account's address, from Gmail if that was granted, else from the
// primary calendar (whose id is the account's address).
async function lookupEmail(client) {
  try {
    const { data } = await client.request({ url: "https://gmail.googleapis.com/gmail/v1/users/me/profile" });
    return data.emailAddress;
  } catch {
    const { data } = await client.request({
      url: "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary",
    });
    return data.id;
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function waitForCode(port, pathname, expectedState) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const reqUrl = new URL(req.url, `http://localhost:${port}`);
      if (reqUrl.pathname !== (pathname || "/oauth2callback")) {
        res.writeHead(404);
        res.end();
        return;
      }
      const code = reqUrl.searchParams.get("code");
      const error = reqUrl.searchParams.get("error");
      res.writeHead(200, { "Content-Type": "text/html" });
      if (error) {
        res.end(`<h2>Authorization failed: ${escapeHtml(error)}</h2>You can close this tab.`);
        server.close();
        reject(new Error(`OAuth error: ${error}`));
        return;
      }
      if (reqUrl.searchParams.get("state") !== expectedState) {
        res.end(`<h2>Authorization failed: state mismatch.</h2>Start again from the terminal.`);
        server.close();
        reject(
          new Error(
            "OAuth state mismatch - the callback didn't come from this sign-in. Run the command again."
          )
        );
        return;
      }
      res.end(`<h2>Account connected.</h2>You can close this tab and go back to the terminal.`);
      server.close();
      resolve(code);
    });
    server.listen(port);
  });
}

// Which products an account can use, from the scopes it granted.
function describeGrants(scopes) {
  if (!Array.isArray(scopes)) return "scopes unknown - re-run auth for this alias";
  const products = Object.entries(REQUIRED_SCOPES)
    .filter(([, needed]) => needed.every((s) => scopes.includes(s)))
    .map(([product]) => product);
  if (scopes.includes(DRIVE_READONLY_SCOPE)) products.push("drive.readonly");
  return products.length ? products.join(", ") : "nothing usable - re-run auth for this alias";
}

async function list() {
  const accounts = loadAccounts();
  const aliases = Object.keys(accounts);
  if (aliases.length === 0) {
    console.log("No Google accounts connected yet. Run: node auth.js <alias>");
    return;
  }
  console.log(`Connected Google accounts (${ACCOUNTS_PATH}):\n`);
  for (const alias of aliases) {
    const acct = accounts[alias];
    const nicknames = acct.nicknames || [];
    const also = nicknames.length ? `  (also: ${nicknames.join(", ")})` : "";
    const from = acct.default_from ? `  [Gmail sends as ${acct.default_from}]` : "";
    console.log(`  ${alias}  ->  ${acct.email}${also}${from}`);
    console.log(`      granted: ${describeGrants(acct.scopes)}`);
  }
  console.log("");
}

async function remove(alias) {
  if (!alias) {
    console.error("Usage: node auth.js --remove <alias>");
    process.exit(1);
  }
  await removeAccount(alias).catch(fail);
  console.log(
    `Removed alias "${alias}". (This only deletes the local token; it does not revoke Google access. Revoke at https://myaccount.google.com/permissions if you want to fully disconnect.)`
  );
}

function fail(err) {
  console.error(err.message);
  process.exit(1);
}

async function nick(alias, nickname) {
  if (!alias || !nickname || !NAME_PATTERN.test(nickname)) {
    console.error("Usage: node auth.js --nick <alias> <nickname>   (nickname: letters, digits, - or _)");
    process.exit(1);
  }
  const owner = await addNickname(alias, nickname).catch(fail);
  console.log(`"${nickname}" now points to account "${owner}".`);
}

async function unnick(nickname) {
  if (!nickname) {
    console.error("Usage: node auth.js --unnick <nickname>");
    process.exit(1);
  }
  const owner = await removeNickname(nickname).catch(fail);
  console.log(`Removed nickname "${nickname}" from account "${owner}".`);
}

function help() {
  console.log(`
Google MCP accounts - one login per Google account, shared by every Google MCP server
(config folder: ${CONFIG_DIR})

  node auth.js <alias>              connect or re-authorize a Google account under <alias>
                                    (re-running overwrites that alias's token)
  node auth.js <alias> --with-drive-readonly
                                    same, plus read access to your whole Drive, so
                                    multi-gdrive-mcp can search files it didn't create
  node auth.js --list               list connected accounts and what each one granted
  node auth.js --remove <alias>     disconnect an account (local token only)
  node auth.js --nick <alias> <nickname>
                                    add another name for an already-connected account
  node auth.js --unnick <nickname>  remove a nickname (the account stays connected)

Example:
  node auth.js personal
  node auth.js work
  node auth.js --nick work w
`);
}

const { cmd, alias, nickname, driveReadonly } = parseArgs();
if (cmd === "connect") await connect(alias, driveReadonly);
else if (cmd === "list") await list();
else if (cmd === "remove") await remove(alias);
else if (cmd === "nick") await nick(alias, nickname);
else if (cmd === "unnick") await unnick(nickname);
else help();
