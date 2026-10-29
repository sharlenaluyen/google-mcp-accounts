#!/usr/bin/env bash
# Signs Google accounts back in when their refresh tokens have expired (Google
# expires them 7 days after sign-in while the OAuth app is in Testing mode),
# then restarts Claude Desktop so the servers pick up the new tokens.
#
# Each account is checked with Google first, and only the ones that have
# expired, or will soon, are signed in again. Aliases, nicknames, settings and
# drive.readonly access are kept.
#
# Runs on macOS, and on Windows in Git Bash (installed with Git for Windows).
#
# Run from a clone:   ./refresh-tokens.sh         (expired or expiring accounts)
#                     ./refresh-tokens.sh --all   (every account)
# Or without one:     bash <(curl -fsSL https://raw.githubusercontent.com/sharlenaluyen/google-mcp-accounts/main/refresh-tokens.sh)

case "$(uname -s)" in
  Darwin) OS=mac ;;
  MINGW* | MSYS* | CYGWIN*) OS=windows ;;
  *) OS=other ;;
esac

ACCOUNTS_REPO="google-mcp-accounts"
GOOGLE_MCP_DIR="${GOOGLE_MCP_DIR:-$HOME/.google-mcp}"
ACCOUNTS_PATH="$GOOGLE_MCP_DIR/accounts.json"
CREDENTIALS_PATH="$GOOGLE_MCP_DIR/credentials.json"
TOKEN_DAYS=7   # how long Google keeps a Testing-mode sign-in
SOON_HOURS=24 # refresh when it ends within this many hours

ACCOUNTS_DIR=""
REFRESH_ALL=0
[[ "$1" == "--all" ]] && REFRESH_ALL=1

if [[ -t 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi

# --- Output and input ---------------------------------------------------------

say() { printf '%s\n' "$*"; }
ok() { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err() { printf '%s✗%s %s\n' "$RED" "$RESET" "$*"; }

banner() {
  printf '\n%s══════════════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
  printf '%s  %s%s\n' "$BOLD" "$1" "$RESET"
  printf '%s══════════════════════════════════════════════════════════════%s\n\n' "$BOLD" "$RESET"
}

input_ended() {
  printf '\n'
  err "Input ended, so this stopped. Accounts already refreshed stay refreshed; run it again any time."
  exit 1
}

# Reads one key. Succeeds for Enter or Space, fails for any other key.
key_go() {
  local key
  IFS= read -rsn1 key || input_ended
  printf '\n'
  [[ -z "$key" || "$key" == " " ]]
}

yes_key() {
  say "$1"
  say "  ${DIM}(ENTER or SPACE = yes, any other key = no)${RESET}"
  key_go
}

pause() {
  printf '\n%s%s%s ' "$DIM" "$1" "$RESET"
  IFS= read -rsn1 _ || input_ended
  printf '\n'
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- Platform -----------------------------------------------------------------
# Git Bash's own commands use /c/Users/... paths; Windows programs (node,
# Claude) and Claude's config use C:\Users\... ones.

native_path() { if [[ "$OS" == windows ]]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
unix_path() { if [[ "$OS" == windows && -n "$1" ]]; then cygpath -u "$1"; else printf '%s' "$1"; fi; }

# A path typed, pasted, or dragged in. Finder escapes spaces; Windows wraps
# the path in quotes and uses C:\ form.
clean_path() {
  local p
  p=$(trim "$1")
  p="${p#\'}" p="${p%\'}" p="${p#\"}" p="${p%\"}"
  if [[ "$OS" == windows ]]; then
    [[ "$p" =~ ^[A-Za-z]:[\\/] ]] && p=$(cygpath -u "$p")
  else
    p="${p//\\ / }"
  fi
  p="${p/#\~/$HOME}"
  printf '%s' "$p"
}

# The Microsoft Store build of Claude keeps its config in its package folder
# once it has written one there; the regular installer uses %APPDATA%.
claude_config_path() {
  if [[ "$OS" == mac ]]; then
    printf '%s' "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    return
  fi
  local f
  for f in "$(unix_path "$LOCALAPPDATA")"/Packages/Claude_*/LocalCache/Roaming/Claude/claude_desktop_config.json; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return; }
  done
  printf '%s' "$(unix_path "$APPDATA")/Claude/claude_desktop_config.json"
}
CLAUDE_CONFIG=$(claude_config_path)

if [[ "$OS" == mac ]]; then
  QUIT_CLAUDE_HINT="Quit Claude with Cmd+Q (not just closing the window)"
else
  QUIT_CLAUDE_HINT="Quit Claude from its icon in the system tray (right-click > Quit, not just closing the window)"
fi

# --- Finding things -----------------------------------------------------------

is_accounts_dir() { [[ -f "$1/auth.js" && -f "$1/store.js" ]]; }

# Next to this script when run from a clone, else wherever Claude's config
# says the servers live, else the setup script's default folder, else ask.
find_accounts_dir() {
  local src="${BASH_SOURCE[0]:-}" dir
  if [[ -n "$src" && -f "$src" ]]; then
    dir=$(cd "$(dirname "$src")" && pwd)
    is_accounts_dir "$dir" && { ACCOUNTS_DIR="$dir"; return; }
  fi
  dir=$(node -e '
    try {
      const path = require("path");
      const servers = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).mcpServers || {};
      const entry = ["multi-gmail", "multi-gcal", "multi-gdrive", "gworkspace-docs-sheets-slides"]
        .map((key) => servers[key])
        .find((e) => e?.args?.[0]);
      if (entry) console.log(path.resolve(entry.args[0], "../../..", process.argv[2]));
    } catch {}' "$(native_path "$CLAUDE_CONFIG")" "$ACCOUNTS_REPO" | tr -d '\r')
  dir=$(unix_path "$dir")
  is_accounts_dir "$dir" && { ACCOUNTS_DIR="$dir"; return; }
  dir="$HOME/google-mcp/$ACCOUNTS_REPO"
  is_accounts_dir "$dir" && { ACCOUNTS_DIR="$dir"; return; }

  while true; do
    read -r -p "Where is your $ACCOUNTS_REPO folder? (drag it here): " dir || input_ended
    dir=$(clean_path "$dir")
    is_accounts_dir "$dir" && { ACCOUNTS_DIR=$(cd "$dir" && pwd); return; }
    err "That folder doesn't have auth.js in it."
  done
}

# One line per account: alias, email, status (ok / expired / unknown:<why>),
# days since sign-in, and 1 if it granted drive.readonly. Only asks Google
# for a short-lived access token; nothing is written.
check_accounts() {
  (cd "$ACCOUNTS_DIR" && node --input-type=module -) <<'EOF'
import { loadAccounts, loadCredentials } from "./store.js";
import { DRIVE_READONLY_SCOPE } from "./scopes.js";
import { OAuth2Client } from "google-auth-library";

const { clientId, clientSecret, redirectUri } = loadCredentials();
const accounts = loadAccounts();
const rows = await Promise.all(
  Object.entries(accounts).map(async ([alias, acct]) => {
    const client = new OAuth2Client(clientId, clientSecret, redirectUri);
    client.setCredentials({ refresh_token: acct.refresh_token });
    let status = "ok";
    try {
      await client.getAccessToken();
    } catch (e) {
      const code = e.response?.data?.error || e.message;
      status = /invalid_grant|unauthorized_client|invalid_client/.test(code) ? "expired" : `unknown:${code}`;
    }
    const age = acct.authorized_at ? (Date.now() - Date.parse(acct.authorized_at)) / 86_400_000 : "";
    const drive = (acct.scopes || []).includes(DRIVE_READONLY_SCOPE) ? 1 : 0;
    return [alias, acct.email, status, age === "" ? "" : age.toFixed(1), drive].join("\t");
  })
);
for (const row of rows) console.log(row);
EOF
}

account_email() {
  node -e 'try { console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]].email); } catch {}' \
    "$(native_path "$ACCOUNTS_PATH")" "$1" | tr -d '\r'
}

claude_running() {
  if [[ "$OS" == mac ]]; then
    pgrep -x Claude >/dev/null
  else
    tasklist.exe //FI "IMAGENAME eq claude.exe" //NH 2>/dev/null | grep -qi 'claude\.exe'
  fi
}

restart_claude() {
  local exe="" i
  if [[ "$OS" == mac ]]; then
    osascript -e 'quit app "Claude"' 2>/dev/null
  else
    # Remember where it runs from, to reopen the same install.
    exe=$(powershell.exe -NoProfile -Command '(Get-Process claude -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1).Path' 2>/dev/null | tr -d '\r')
    taskkill.exe //IM claude.exe //F >/dev/null 2>&1
  fi
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    claude_running || break
    sleep 1
  done
  if [[ "$OS" == mac ]]; then
    open -a Claude && ok "Claude Desktop restarted."
    return
  fi
  [[ -n "$exe" ]] || exe="$LOCALAPPDATA\\AnthropicClaude\\claude.exe"
  if powershell.exe -NoProfile -Command "Start-Process -FilePath '$exe'" >/dev/null 2>&1; then
    ok "Claude Desktop restarted."
  else
    warn "Closed Claude Desktop, but couldn't reopen it. Open it from the Start menu."
  fi
}

# --- Main ---------------------------------------------------------------------

main() {
  # When piped in (curl | bash), stdin is the script itself; read keys from the terminal.
  [[ -t 0 ]] || exec </dev/tty

  banner "Refresh Google sign-ins"

  if [[ "$OS" == other ]]; then
    err "This works on macOS, and on Windows in Git Bash (not WSL). Nothing was changed."
    exit 1
  fi

  command -v node >/dev/null || { err "Node.js isn't installed. Run setup.sh first."; exit 1; }
  find_accounts_dir
  if [[ ! -f "$CREDENTIALS_PATH" || ! -f "$ACCOUNTS_PATH" ]]; then
    err "Nothing is set up yet (no $CREDENTIALS_PATH or $ACCOUNTS_PATH). Run setup.sh first."
    exit 1
  fi
  if [[ ! -d "$ACCOUNTS_DIR/node_modules" ]]; then
    say "Installing $ACCOUNTS_REPO's dependencies first..."
    (cd "$ACCOUNTS_DIR" && npm ci --no-fund --no-audit) || { err "npm ci failed in $ACCOUNTS_DIR"; exit 1; }
  fi

  say "Checking each account's sign-in with Google..."
  local checked
  checked=$(check_accounts) || { err "Couldn't check the accounts (see the error above)."; exit 1; }
  if [[ -z "$checked" ]]; then
    warn "No Google accounts are connected. Run setup.sh to connect some."
    exit 0
  fi

  local aliases=() emails=() drives=() reasons=() alias email status age drive hours reason
  say ""
  while IFS=$'\t' read -r alias email status age drive; do
    reason=""
    hours=""
    [[ -n "$age" ]] && hours=$(awk -v a="$age" -v t="$TOKEN_DAYS" 'BEGIN { printf "%d", (t - a) * 24 }')
    case "$status" in
      ok)
        if [[ -n "$hours" ]] && ((hours < SOON_HOURS)); then
          warn "$alias ($email): signed in, but it ends in about $((hours < 1 ? 1 : hours)) hours (Testing-mode sign-ins last $TOKEN_DAYS days)"
          reason="ends within $SOON_HOURS hours"
        else
          ok "$alias ($email): signed in${hours:+ (about $((hours / 24)) days left if your app is in Testing mode)}"
        fi
        ;;
      expired)
        err "$alias ($email): expired"
        reason="expired"
        ;;
      *)
        warn "$alias ($email): couldn't check (${status#unknown:})"
        ;;
    esac
    [[ "$REFRESH_ALL" == 1 && -z "$reason" ]] && reason="--all"
    if [[ -n "$reason" ]]; then
      aliases+=("$alias")
      emails+=("$email")
      drives+=("$drive")
      reasons+=("$reason")
    fi
  done <<<"$checked"
  say ""

  if [[ ${#aliases[@]} == 0 ]]; then
    ok "Nothing to refresh."
    say "${DIM}To sign every account in again anyway: ./refresh-tokens.sh --all${RESET}"
    exit 0
  fi

  say "${BOLD}${#aliases[@]} to refresh.${RESET} For each one, your browser opens and you sign in as that account."
  local i refreshed=0 cancelled after flags
  for i in "${!aliases[@]}"; do
    alias="${aliases[$i]}"
    email="${emails[$i]}"
    printf '\n%s── %s (%s)%s %s\n\n' "$BOLD" "$alias" "$email" "$RESET" "${DIM}${reasons[$i]}${RESET}"
    yes_key "Refresh it now?" || { say "Skipped $alias."; continue; }
    say "In the browser:"
    say "  1. Pick ${BOLD}$email${RESET}. ${DIM}(A different account would take over the alias \"$alias\".)${RESET}"
    say "  2. On \"Google hasn't verified this app\", click ${BOLD}Continue${RESET}."
    say "  3. Leave ${BOLD}every permission ticked${RESET} and click ${BOLD}Continue${RESET}."
    say "${DIM}(Press Ctrl+C here to cancel this one.)${RESET}"
    pause "Press any key to open the browser."

    flags=()
    [[ "${drives[$i]}" == 1 ]] && flags=(--with-drive-readonly)
    cancelled=0
    trap 'cancelled=1' INT
    (cd "$ACCOUNTS_DIR" && node auth.js "$alias" "${flags[@]}")
    status=$?
    trap - INT
    if [[ "$cancelled" == 1 || "$status" != 0 ]]; then
      warn "$alias wasn't refreshed. Its old sign-in is unchanged."
      continue
    fi
    after=$(account_email "$alias")
    if [[ "$after" != "$email" ]]; then
      warn "\"$alias\" is now $after instead of $email. Run this again with --all and sign in as $email to put it back."
    fi
    refreshed=$((refreshed + 1))
  done

  banner "Done"
  ok "Refreshed $refreshed of ${#aliases[@]}."
  if ((refreshed > 0)) && claude_running; then
    say ""
    if yes_key "Claude Desktop keeps using the old sign-ins until it restarts. Quit and reopen it now?"; then
      restart_claude
    else
      say "$QUIT_CLAUDE_HINT and reopen it when you're ready."
    fi
  fi
}

[[ -n "${REFRESH_SH_NO_MAIN:-}" ]] || { main "$@"; exit $?; }
