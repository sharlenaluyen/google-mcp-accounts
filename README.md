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
| `store.js` | Accounts by alias, with nicknames and arbitrary per-account fields. Writes are atomic (temp file + rename), `0600`, in a `0700` folder, and serialized in-process so concurrent tool calls can't lose an update. |
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
| `calendar.calendarlist.readonly` | multi-gcal-mcp | **Added beyond the original plan.** `calendar.events` can't list your calendars (`calendarList.list` rejects it), so `list_calendars` needs this one. It's the narrowest scope that allows the call: read-only, and only the list of calendars you're subscribed to. |
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

1. Enable the Gmail, Calendar, Drive, Docs, Sheets, and Slides APIs on your
   Google Cloud project (already done for this project).
2. Put the OAuth **Desktop app** client JSON at `~/.google-mcp/credentials.json`:

   ```bash
   mkdir -p ~/.google-mcp && chmod 700 ~/.google-mcp
   cp /path/to/downloaded/client.json ~/.google-mcp/credentials.json
   chmod 600 ~/.google-mcp/credentials.json
   ```

3. Install and connect each account:

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

### Coming from multi-gmail-mcp's old `~/.multi-gmail-mcp/`

```bash
node auth.js --import-legacy          # copies accounts.json + credentials.json, never overwrites
node auth.js --list                   # imported accounts show "granted: gmail"
node auth.js work                     # re-authorize each one to add Calendar/Drive/Docs/Sheets/Slides
```

The old folder is left untouched. Delete it yourself once everything works.

## CLI

```
node auth.js <alias>                        connect or re-authorize a Google account
node auth.js <alias> --with-drive-readonly  same, plus read access to the whole Drive
node auth.js --list                         accounts, nicknames, and what each one granted
node auth.js --remove <alias>               disconnect (local token only)
node auth.js --nick <alias> <nickname>      another name for the same account
node auth.js --unnick <nickname>            remove a nickname
node auth.js --import-legacy [dir]          one-time import from ~/.multi-gmail-mcp
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
- The in-process write queue doesn't coordinate *between* processes (for
  example, the auth CLI and the Gmail server writing at the same instant).
  The atomic rename keeps the file valid either way, but one of the two
  writes can be lost. Both writers are rare and human-initiated, so in
  practice this doesn't come up.

## Dependency on a sibling folder: the tradeoff

The servers reference this package as `file:../google-mcp-accounts`. That
works because all five repos are siblings on disk today. If they're pushed to
separate GitHub remotes and cloned somewhere they **aren't** siblings, switch
each server's dependency to a git URL, for example
`"google-mcp-accounts": "github:<you>/google-mcp-accounts#v1.0.0"`.
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
