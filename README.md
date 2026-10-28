# google-mcp-accounts

The one shared piece of the local Google MCP servers: **log into each Google
account once**, and every server can use it.

| Server | What it does |
| --- | --- |
| [multi-gmail-mcp](../multi-gmail-mcp) | Gmail |
| [multi-gcal-mcp](../multi-gcal-mcp) | Google Calendar |
| [multi-gdrive-mcp](../multi-gdrive-mcp) | Google Drive |
| [gworkspace-docs-sheets-slides-mcp](../gworkspace-docs-sheets-slides-mcp) | Docs, Sheets, Slides |

This package owns the security-sensitive state those servers share:

- **`~/.google-mcp/accounts.json`**: one refresh token per Google account,
  keyed by an alias you choose (`work`, `personal`, ...), plus per-account
  settings such as Gmail's `default_from`.
- **`~/.google-mcp/audit.log`**: an append-only log of every send, share,
  delete, and other action with visible side effects, from every server.

Only this repo's `auth.js` writes OAuth tokens to `accounts.json`. The servers
only read it, and they refresh access tokens in memory. The one exception is
multi-gmail-mcp's `set_default_from`/`clear_default_from`. It changes a single
non-credential setting, and it goes through this package's `setAccountField`,
which refuses to touch `refresh_token`, `email`, `nicknames`, or `scopes`.

## What's in it

| Module | Purpose |
| --- | --- |
| `store.js` | Accounts by alias, with nicknames and arbitrary per-account fields. Writes are atomic (temp file + rename), `0600`, in a `0700` folder. Every read-modify-write holds a lock file (`accounts.json.lock`), so two processes writing at once (the auth CLI and the Gmail server, say) can't lose each other's update. There's no unlocked way to write the file. |
| `accounts.js` | `getAccountInfo`, `getConnectedAliases`, and `createAuthClient(alias, { OAuth2, requiredScopes })`. That last one builds a self-refreshing OAuth client, and if the account never granted a needed scope it fails up front with "re-run auth for this alias". |
| `audit.js` | `logAuditEvent` / `createAuditLogger(serverName)`. JSONL, `0600`, best-effort (it never blocks the action it records), and it never logs content. |
| `retry.js` | `withRetry` exponential backoff on 429/5xx. It's only for reads and idempotent calls. Sends, shares, invites, and edits are never auto-retried. |
| `files.js` | `createFilesFolder(dir)` confines a server's local reads/writes to one folder (resolves symlinks, rejects `../`). `statRegularFile` checks a file's real size on disk. |
| `scopes.js` | The scope list below, and which scopes each server requires. |
| `auth.js` | The CLI (also installed as the `google-mcp-auth` bin). |

The servers import it as `import { ... } from "google-mcp-accounts"` (or the
subpaths `google-mcp-accounts/store`, `/audit`, `/retry`, `/accounts`,
`/files`, `/scopes`).

## Scopes requested

`node auth.js <alias>` asks for all of these in **one** consent screen:

| Scope | Used by | Why |
| --- | --- | --- |
| `gmail.readonly`, `gmail.send`, `gmail.modify`, `gmail.labels` | multi-gmail-mcp | Read, draft, send, and label. `gmail.modify` alone covers all of it, and it's the only one the server checks for. The other three are listed so the consent screen spells each capability out. None of them allow permanent deletion of mail. |
| `calendar.events` | multi-gcal-mcp | Read, create, update, delete, and respond to events. |
| `calendar.calendarlist.readonly` | multi-gcal-mcp | `calendar.events` can't list your calendars (`calendarList.list` rejects it), so `list_calendars` needs this one. It's the narrowest scope that allows the call: read-only, and only the list of calendars you're subscribed to. |
| `drive.file` | multi-gdrive-mcp, and Slides export | Only files this OAuth client created or opened, **not your whole Drive**. |
| `documents` | gworkspace-docs-sheets-slides-mcp | Read/edit Google Docs. |
| `spreadsheets` | gworkspace-docs-sheets-slides-mcp | Read/edit Google Sheets. |
| `presentations` | gworkspace-docs-sheets-slides-mcp | Read/create/edit Google Slides. |

**Opt-in escalation:** `node auth.js <alias> --with-drive-readonly` also
requests `drive.readonly`. That lets multi-gdrive-mcp search and download
*any* file in that Drive (not just the ones it created), and lets
`export_presentation` export decks you made in the browser. It's never
requested by default. It's a deliberate per-account choice, and
`--list` shows which accounts have it.

Google's consent screen lets you untick individual permissions. Whatever you
actually grant is recorded, and a server whose scope you didn't grant tells
you to re-run auth instead of failing with an opaque 403.

## Setup

On macOS, `setup.sh` walks you through every step below, one at a time, and
connects the servers to Claude Desktop. It's safe to re-run. Without cloning:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sharlenaluyen/google-mcp-accounts/main/setup.sh)
```

To do it by hand instead:

You need one Google Cloud project with one OAuth client. Every account you
connect, and all four servers, share it. You only do steps 1-5 once.

1. **Create a project.** Go to <https://console.cloud.google.com/>, open the
   project picker at the top of the page, and click **New project**. Give it
   any name (e.g. `google-mcp`). No organization is needed. Make sure the new
   project is selected in the picker before going on.

2. **Enable the APIs.** Go to **APIs & Services → Library**, then search for
   and **Enable** each of these:
   - Gmail API
   - Google Calendar API
   - Google Drive API
   - Google Docs API
   - Google Sheets API
   - Google Slides API

   If you skip one, its server fails with a 403 that says the API "has not
   been used in project ... or it is disabled".

3. **Set up the OAuth consent screen.** Go to **APIs & Services → OAuth
   consent screen** (also called **Google Auth Platform**) and click **Get
   started**:
   - **App information**: any app name (e.g. `Google MCP`), and your email as
     the support email.
   - **Audience**: **External** (pick **Internal** only if every account you
     connect is in the same Google Workspace organization as the project).
   - **Contact information**: your email.
   - Agree to the policy and click **Create**.

   You don't need to add scopes here. `auth.js` asks for them itself, and
   Google shows them on the consent screen.

4. **Add test users.** A new External app is in **Testing** mode, and only
   listed test users can sign in to it. Go to **Audience → Test users → Add
   users** and add **every Google address you'll connect** (work, personal,
   ...). Up to 100 are allowed. Signing in with an address that isn't listed
   fails with `Error 403: access_denied`.

   Leave the app in Testing. It's fine for personal use, and you never need
   Google's verification. When you connect an account, Google warns that it
   "hasn't verified this app". Click **Continue** (on some screens it's under
   **Advanced**). Note that in Testing mode Google expires refresh tokens
   after 7 days, so you'll re-run `node auth.js <alias>` about weekly (see
   [CLI](#cli)).

5. **Create the OAuth client.** Go to **Clients** (or **APIs & Services →
   Credentials → Create credentials → OAuth client ID**):
   - **Application type**: **Desktop app**. Not "Web application": `auth.js`
     listens on `http://localhost:53682` for the redirect, and only Desktop
     clients accept any loopback port without registering it.
   - **Name**: anything (e.g. `google-mcp-auth`).
   - Click **Create**, then **Download JSON** in the dialog (or later, from
     the download icon next to the client in the list).

   The client secret in this file isn't treated as a real secret by Google
   for Desktop apps, but keep it out of repos anyway.

6. Put the downloaded client JSON at `~/.google-mcp/credentials.json`:

   ```bash
   mkdir -p ~/.google-mcp && chmod 700 ~/.google-mcp
   cp /path/to/downloaded/client.json ~/.google-mcp/credentials.json
   chmod 600 ~/.google-mcp/credentials.json
   ```

7. Install and connect each account. Each `node auth.js <alias>` opens a
   browser. Sign in as that account, click through the unverified-app
   warning, and leave every permission ticked:

   ```bash
   cd google-mcp-accounts
   npm install
   node auth.js work
   node auth.js personal
   node auth.js --list
   ```

Install this package **before** `npm install` in any of the four servers.
They depend on it as `"google-mcp-accounts": "file:../google-mcp-accounts"`,
and its own dependencies have to be present for them to load it.

## Connect to Claude

This package isn't an MCP server itself, so it gets no entry in Claude's
config. The four servers do. Do these steps in this order, so Claude never
starts a server that can't load its accounts:

1. **Install this package**: `cd google-mcp-accounts && npm install`.
2. **Connect your accounts** with `node auth.js <alias>`, once per Google
   account, then check with `node auth.js --list`. Each one should show
   Gmail, Calendar, Drive, Docs, Sheets, and Slides as granted.
3. **Update multi-gmail-mcp** to the version that uses this package, and
   run `npm install` there. It finds no accounts until step 2 is done.
4. **Install the other three servers**: `npm install` in multi-gcal-mcp,
   multi-gdrive-mcp, and gworkspace-docs-sheets-slides-mcp.
5. **Add the servers to Claude.** For Claude Desktop on macOS, edit
   `~/Library/Application Support/Claude/claude_desktop_config.json`. Use
   absolute paths, and keep any other servers already in `mcpServers`:

   ```json
   {
     "mcpServers": {
       "multi-gmail": {
         "command": "node",
         "args": ["/absolute/path/to/multi-gmail-mcp/src/server.js"],
         "env": { "MULTI_GMAIL_MCP_FILES_DIR": "/Users/you/Downloads/google-mcp-files" }
       },
       "multi-gcal": {
         "command": "node",
         "args": ["/absolute/path/to/multi-gcal-mcp/src/server.js"]
       },
       "multi-gdrive": {
         "command": "node",
         "args": ["/absolute/path/to/multi-gdrive-mcp/src/server.js"],
         "env": { "MULTI_GDRIVE_MCP_FILES_DIR": "/Users/you/Downloads/google-mcp-files" }
       },
       "gworkspace-docs-sheets-slides": {
         "command": "node",
         "args": ["/absolute/path/to/gworkspace-docs-sheets-slides-mcp/src/server.js"],
         "env": { "GWORKSPACE_MCP_FILES_DIR": "/Users/you/Downloads/google-mcp-files" }
       }
     }
   }
   ```

   The `env` lines point every server at **one shared files folder**
   (see below). Each server's README lists its other optional settings.
6. **Fully quit and reopen Claude Desktop** (Cmd+Q, not just closing the
   window). The four servers should show up under the tools icon in a chat.
   In each one, call `list_accounts` to check that it sees your accounts.

### One files folder for all the servers

Each server reads and writes local files only inside its own files folder,
and by default each has a different one (`~/Downloads/gmail-mcp`,
`~/Downloads/drive-mcp`, `~/Downloads/gworkspace-mcp`). That breaks any
request that crosses servers. For example, "attach this Drive doc to my
email" needs Drive's `download_file` to save the file where Gmail's
`attach_document` can read it, and with separate folders it can't.

The fix is config only, no code: set `MULTI_GMAIL_MCP_FILES_DIR`,
`MULTI_GDRIVE_MCP_FILES_DIR` and `GWORKSPACE_MCP_FILES_DIR` to the **same
absolute path** in each server's `env` block, as in the example above, and
then fully restart Claude Desktop. Each server still refuses files outside
that one folder, so the protection stays the same; the servers just share
it. multi-gcal-mcp never touches local files, so it needs no setting.

If you share the folder, a file downloaded by any server can be attached or
uploaded by any other one. Keep anything you wouldn't email out of that
folder.

## CLI

```
node auth.js <alias>                        connect or re-authorize a Google account
node auth.js <alias> --with-drive-readonly  same, plus read access to the whole Drive
node auth.js --list                         accounts, nicknames, and what each one granted
node auth.js --remove <alias>               disconnect (local token only)
node auth.js --nick <alias> <nickname>      another name for the same account
node auth.js --unnick <nickname>            remove a nickname
```

**Re-running `node auth.js <alias>` re-authorizes and overwrites that alias's
token**, keeping its nicknames and settings. Do this when:
- the scope list changes (e.g. after updating this package, or to add
  `--with-drive-readonly`);
- you revoked the app's access at <https://myaccount.google.com/permissions>;
- a server reports `invalid_grant` (Google expired the token; this happens
  after 7 days while the OAuth consent screen is in "Testing" mode).

Connecting an address that's already connected under another alias doesn't
create a duplicate. It refreshes the existing entry and adds the new name as
a nickname.

`--remove` only deletes the local token. To fully revoke access, also remove
the app at <https://myaccount.google.com/permissions>.

Set `GOOGLE_MCP_DIR` to use a folder other than `~/.google-mcp` (the tests
do this so they never touch your real tokens).

## Security notes

- `credentials.json`, `accounts.json`, and `*.log` are gitignored here and in
  every server repo. They belong in `~/.google-mcp/`, never in a repo.
- The OAuth callback checks a random `state` value, so a stray local request
  can't swap in a code for a different Google account.
- **Concurrent writes.** Each write reads `accounts.json`, changes it, and
  saves it while holding `~/.google-mcp/accounts.json.lock`. The lock is
  created with `O_EXCL`, so only one process can hold it. Others wait and
  retry for up to 10 seconds. A lock left by a crashed process is cleared
  when its process is no longer running, or when it's over 30 seconds old.
  Normally a write holds it for a few milliseconds. If a write ever times
  out, the error names the process holding the lock. Reads don't take the
  lock: the atomic rename means they always see a complete file.

## Dependency on a sibling folder: the tradeoff

The servers reference this package as `file:../google-mcp-accounts`. That
works because all five repos are siblings on disk today. If they're pushed to
separate GitHub remotes and cloned somewhere they **aren't** siblings, switch
each server's dependency to a git URL, for example
`"google-mcp-accounts": "github:sharlenaluyen/google-mcp-accounts#v1.0.0"`
(after tagging a release here).
Pin a tag so a change here can't silently alter four servers at once.
The upside of `file:` is that changes here reach every server immediately,
with no publish step. The downside is that it only works with this exact
folder layout.

## Development

```bash
npm test      # node:test - store, audit, retry, accounts, files, scopes
npm run lint
npm run format
```
