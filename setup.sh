#!/usr/bin/env bash
# Guided setup for the local Google MCP servers: Google Cloud project, OAuth
# client, cloning the repos, connecting accounts, and wiring it all into
# Claude Desktop. macOS only.
#
# Run from a clone:   ./setup.sh
# Or without one:     bash <(curl -fsSL https://raw.githubusercontent.com/sharlenaluyen/google-mcp-accounts/main/setup.sh)

GH_OWNER="sharlenaluyen"
ACCOUNTS_REPO="google-mcp-accounts"
REPOS=(multi-gmail-mcp multi-gcal-mcp multi-gdrive-mcp gworkspace-docs-sheets-slides-mcp)
REPO_LABELS=("Gmail" "Google Calendar" "Google Drive" "Google Docs, Sheets & Slides")
APIS=(gmail.googleapis.com calendar-json.googleapis.com drive.googleapis.com docs.googleapis.com sheets.googleapis.com slides.googleapis.com)

GOOGLE_MCP_DIR="${GOOGLE_MCP_DIR:-$HOME/.google-mcp}"
CREDENTIALS_PATH="$GOOGLE_MCP_DIR/credentials.json"
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
NAME_PATTERN='^[A-Za-z0-9_-]+$'

PROJECT_ID=""
USE_GCLOUD=0
BASE_DIR=""
ACCOUNTS_DIR=""
SELECTED=()

if [[ -t 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' CYAN=$'\033[36m' RESET=$'\033[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
fi

# --- Output -------------------------------------------------------------------

say() { printf '%s\n' "$*"; }
ok() { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err() { printf '%s✗%s %s\n' "$RED" "$RESET" "$*"; }
link() { printf '  %s%s%s\n' "$CYAN" "$1" "$RESET"; }

banner() {
  printf '\n%s══════════════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
  printf '%s  %s%s\n' "$BOLD" "$1" "$RESET"
  printf '%s══════════════════════════════════════════════════════════════%s\n\n' "$BOLD" "$RESET"
}

step() { printf '\n%s── Step %s: %s%s\n\n' "$BOLD" "$1" "$2" "$RESET"; }

# --- Input --------------------------------------------------------------------

# Reads one key. Succeeds for Enter or Space, fails for any other key.
key_go() {
  local key
  IFS= read -rsn1 key
  printf '\n'
  [[ -z "$key" || "$key" == " " ]]
}

# Asks before a section: Enter/Space runs it, any other key skips it.
section_gate() {
  banner "Section $1: $2"
  say "$3"
  say ""
  say "  ${BOLD}Press ENTER or SPACE${RESET} to start this section."
  say "  ${BOLD}Press ANY OTHER KEY${RESET} to skip it."
  key_go
}

# Enter/Space = yes, any other key = no.
yes_key() {
  say "$1"
  say "  ${DIM}(ENTER or SPACE = yes, any other key = no)${RESET}"
  key_go
}

pause() {
  # Not ${1:-...}: bash 3.2 misreads an apostrophe inside that default.
  local message="When you're done, press any key for the next step."
  [[ -n "$1" ]] && message="$1"
  printf '\n%s%s%s ' "$DIM" "$message" "$RESET"
  IFS= read -rsn1 _
  printf '\n'
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# A path typed, pasted, or dragged in from Finder (which escapes spaces).
clean_path() {
  local p
  p=$(trim "$1")
  p="${p#\'}" p="${p%\'}" p="${p#\"}" p="${p%\"}"
  p="${p//\\ / }"
  p="${p/#\~/$HOME}"
  printf '%s' "$p"
}

# A Cloud Console link, scoped to the project when we know its ID.
console_url() {
  local url="https://console.cloud.google.com/$1"
  if [[ -n "$PROJECT_ID" ]]; then
    [[ "$url" == *\?* ]] && url="$url&project=$PROJECT_ID" || url="$url?project=$PROJECT_ID"
  fi
  printf '%s' "$url"
}

open_url() {
  link "$1"
  open "$1" 2>/dev/null
}

# --- Assumptions --------------------------------------------------------------

confirm_or_quit() {
  say "$1"
  say "  ${DIM}(ENTER or SPACE = yes, any other key = quit setup)${RESET}"
  if ! key_go; then
    say "Come back and run this again once that's sorted."
    exit 0
  fi
}

check_github_ssh() {
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 |
    grep -q "successfully authenticated"
}

check_assumptions() {
  banner "Before we start"

  if [[ "$(uname)" != "Darwin" ]]; then
    err "This script is for macOS (it sets up Claude Desktop's Mac config)."
    exit 1
  fi

  local missing=0 tool
  for tool in git node npm; do
    if ! command -v "$tool" >/dev/null; then
      err "$tool isn't installed."
      missing=1
    fi
  done
  if [[ "$missing" == 1 ]]; then
    say "Install Node.js 20 or newer (it includes npm) from https://nodejs.org, and git with: xcode-select --install"
    exit 1
  fi
  if (($(node -p 'process.versions.node.split(".")[0]') < 20)); then
    err "Node.js $(node -v) is too old. Install version 20 or newer from https://nodejs.org"
    exit 1
  fi
  ok "git, Node.js $(node -v) and npm are installed."

  say "Checking that you can clone from GitHub over SSH..."
  until check_github_ssh; do
    err "GitHub SSH isn't working on this Mac yet (git@github.com didn't accept your key)."
    say "Set it up with GitHub's guide:"
    link "https://docs.github.com/en/authentication/connecting-to-github-with-ssh"
    say ""
    say "  Press ENTER or SPACE to check again, any other key to quit."
    key_go || exit 0
  done
  ok "GitHub SSH works."

  if [[ -d /Applications/Claude.app || -d "$HOME/Applications/Claude.app" ]]; then
    ok "Claude Desktop is installed."
  else
    warn "Couldn't find Claude.app in Applications."
  fi
  say ""
  confirm_or_quit "Is Claude Desktop downloaded and are you signed in to it?"
  confirm_or_quit "Do you have more than one Google account, and are you signed in to all of them in your browser?"
  ok "All set."
}

# --- Section 1: Google Cloud --------------------------------------------------

gcloud_ready() {
  command -v gcloud >/dev/null &&
    [[ -n "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ]]
}

# Newest Google OAuth client download in Downloads or Desktop.
find_client_json() {
  ls -t "$HOME/Downloads"/client_secret_*.json "$HOME/Desktop"/client_secret_*.json 2>/dev/null | head -1
}

# 0 = a Desktop app client, 2 = a Web application client, 1 = not a client file.
check_client_json() {
  node -e 'try { const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.exit(j.installed ? 0 : j.web ? 2 : 1); } catch { process.exit(1); }' "$1"
}

# Finds the downloaded client JSON (waiting for it if needed) and moves it to
# ~/.google-mcp/credentials.json.
install_credentials() {
  local src status
  if [[ -f "$CREDENTIALS_PATH" ]] && check_client_json "$CREDENTIALS_PATH"; then
    ok "You already have an OAuth client at $CREDENTIALS_PATH."
    yes_key "Replace it with a newly downloaded one?" || return 0
  fi

  while true; do
    src=$(find_client_json)
    if [[ -z "$src" ]]; then
      say "Waiting for the download (client_secret_....json) to show up in Downloads..."
      say "  ${DIM}(press any key to type the file's location instead)${RESET}"
      while [[ -z "$src" ]]; do
        IFS= read -rsn1 -t 2 _ && break
        src=$(find_client_json)
      done
    fi
    if [[ -n "$src" ]]; then
      say "Found: ${BOLD}$src${RESET}  ${DIM}(downloaded $(stat -f '%Sm' "$src"))${RESET}"
      yes_key "Use this file?" || src=""
    fi
    if [[ -z "$src" ]]; then
      read -r -p "Drag the file into this window (or paste its path), then press Enter: " src
      src=$(clean_path "$src")
    fi

    check_client_json "$src"
    status=$?
    if [[ "$status" == 0 ]]; then
      break
    elif [[ "$status" == 2 ]]; then
      err "That's a \"Web application\" client. Go back to step 5 and create a ${BOLD}Desktop app${RESET} client instead."
    else
      err "\"$src\" isn't a Google OAuth client file."
    fi
    say "  Press ENTER or SPACE to try again, any other key to skip this for now."
    key_go || return 1
  done

  mkdir -p "$GOOGLE_MCP_DIR" && chmod 700 "$GOOGLE_MCP_DIR"
  mv "$src" "$CREDENTIALS_PATH" && chmod 600 "$CREDENTIALS_PATH"
  ok "Moved it to $CREDENTIALS_PATH (readable only by you)."
}

google_project_step() {
  step "1 of 6" "Create a Google Cloud project"
  if gcloud_ready && yes_key "You have the gcloud CLI signed in. Create the project with it, so you don't have to click through?"; then
    PROJECT_ID="google-mcp-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
    if gcloud projects create "$PROJECT_ID" --name="Google MCP"; then
      ok "Created project $PROJECT_ID."
      USE_GCLOUD=1
      pause
      return
    fi
    warn "gcloud couldn't create the project. Let's do it in the browser instead."
    PROJECT_ID=""
  fi

  say "Opening the Google Cloud \"New project\" page:"
  open_url "https://console.cloud.google.com/projectcreate"
  say ""
  say "  1. Project name: anything, e.g. ${BOLD}google-mcp${RESET}"
  say "  2. Organization / Location: leave as is (\"No organization\" is fine)."
  say "  3. Click ${BOLD}Create${RESET} and wait a few seconds for it to finish."
  pause "When the project is created, press any key."

  say ""
  say "Paste the project ${BOLD}ID${RESET} (shown under the project name, e.g. google-mcp-471203),"
  say "so the next links open straight to this project. Just press Enter to skip."
  local id
  read -r -p "> " id
  id=$(trim "$id")
  if [[ "$id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    PROJECT_ID="$id"
    ok "Using project $PROJECT_ID."
  elif [[ -n "$id" ]]; then
    warn "That doesn't look like a project ID, so the links will open without one. Pick the project in the picker at the top of each page."
  else
    say "OK. On each page, make sure your new project is selected in the picker at the top."
  fi
  pause
}

google_apis_step() {
  step "2 of 6" "Enable the Google APIs"
  if [[ "$USE_GCLOUD" == 1 ]]; then
    say "Enabling Gmail, Calendar, Drive, Docs, Sheets and Slides APIs with gcloud..."
    if gcloud services enable "${APIS[@]}" --project "$PROJECT_ID"; then
      ok "All six APIs are enabled."
      pause
      return
    fi
    warn "gcloud couldn't enable them. Let's do it in the browser instead."
  fi

  local ids
  ids=$(IFS=,; printf '%s' "${APIS[*]}")
  say "Opening a page that enables all six APIs at once (Gmail, Calendar, Drive, Docs, Sheets, Slides):"
  open_url "$(console_url "flows/enableapi?apiid=$ids")"
  say ""
  say "  1. Check that your new project is the one selected."
  say "  2. Click ${BOLD}Next${RESET}, then ${BOLD}Enable${RESET}."
  say ""
  say "${DIM}If that page doesn't work, go to APIs & Services → Library and enable each one by name.${RESET}"
  pause
}

google_consent_step() {
  step "3 of 6" "Set up the OAuth consent screen"
  say "Opening Google Auth Platform:"
  open_url "$(console_url "auth/overview")"
  say ""
  say "  1. Click ${BOLD}Get started${RESET}."
  say "  2. App information: App name ${BOLD}Google MCP${RESET}, User support email: your email. ${BOLD}Next${RESET}."
  say "  3. Audience: ${BOLD}External${RESET}. ${BOLD}Next${RESET}."
  say "  4. Contact information: your email. ${BOLD}Next${RESET}."
  say "  5. Tick the agreement and click ${BOLD}Create${RESET}."
  say ""
  say "${DIM}You don't need to add any scopes here; the sign-in step asks for them itself.${RESET}"
  pause
}

google_test_users_step() {
  step "4 of 6" "Add your Google accounts as test users"
  say "Opening the Audience page:"
  open_url "$(console_url "auth/audience")"
  say ""
  say "  1. Under ${BOLD}Test users${RESET}, click ${BOLD}+ Add users${RESET}."
  say "  2. Enter ${BOLD}every Google address you're going to connect${RESET} (work, personal, ...)."
  say "  3. Click ${BOLD}Save${RESET}."
  say ""
  say "Leave the app in ${BOLD}Testing${RESET}. Any address you leave off here gets \"Error 403: access_denied\" when it signs in."
  pause
}

google_client_step() {
  step "5 of 6" "Create the OAuth client and download it"
  say "Opening the \"Create client\" page:"
  open_url "$(console_url "auth/clients/create")"
  say ""
  say "  1. Application type: ${BOLD}Desktop app${RESET}  (not \"Web application\")."
  say "  2. Name: anything, e.g. ${BOLD}google-mcp-auth${RESET}."
  say "  3. Click ${BOLD}Create${RESET}."
  say "  4. In the dialog that pops up, click ${BOLD}Download JSON${RESET}. Save it to Downloads (the default)."
  pause "When the file has downloaded, press any key."
}

google_credentials_step() {
  step "6 of 6" "Put the client file where the servers look for it"
  install_credentials
  pause
}

section_google() {
  section_gate 1 "Google Cloud setup" \
    "Creates the Google Cloud project and OAuth client every account and server shares. You only ever do this once." ||
    return 0
  google_project_step
  google_apis_step
  google_consent_step
  google_test_users_step
  google_client_step
  google_credentials_step
  ok "Google Cloud setup is done."
}

# --- Section 2: Repos, accounts, Claude ---------------------------------------

# Running from inside a clone of this repo: put the servers next to it.
detect_accounts_dir() {
  local src="${BASH_SOURCE[0]:-}" dir
  [[ -n "$src" && -f "$src" ]] || return 1
  dir=$(cd "$(dirname "$src")" && pwd)
  [[ "$(basename "$dir")" == "$ACCOUNTS_REPO" && -f "$dir/auth.js" && -f "$dir/store.js" ]] || return 1
  ACCOUNTS_DIR="$dir"
  BASE_DIR=$(dirname "$dir")
}

clone_or_update() {
  local repo="$1" dest="$BASE_DIR/$1"
  if [[ -d "$dest/.git" ]]; then
    say "$repo is already at $dest. Pulling the latest..."
    git -C "$dest" pull --ff-only || warn "Couldn't update $repo (local changes?). Using it as it is."
  elif [[ -e "$dest" ]]; then
    err "$dest already exists and isn't a git repo. Move it out of the way and run this again."
    return 1
  else
    git clone "git@github.com:$GH_OWNER/$repo.git" "$dest" || return 1
  fi
}

npm_install() {
  say "Installing $(basename "$1")'s dependencies..."
  (cd "$1" && npm install --no-fund --no-audit) || { err "npm install failed in $1"; return 1; }
  ok "$(basename "$1") is installed."
}

repos_accounts_step() {
  step "1 of 5" "Get google-mcp-accounts"
  if detect_accounts_dir; then
    ok "You're running this from $ACCOUNTS_DIR, so the servers will go next to it in $BASE_DIR."
  else
    say "Where should the repos go? Press Enter for the default."
    local dir
    read -r -p "Folder [$HOME/google-mcp]: " dir
    dir=$(clean_path "${dir:-$HOME/google-mcp}")
    mkdir -p "$dir" || { err "Couldn't create $dir"; exit 1; }
    BASE_DIR=$(cd "$dir" && pwd)
    ACCOUNTS_DIR="$BASE_DIR/$ACCOUNTS_REPO"
  fi
  clone_or_update "$ACCOUNTS_REPO" || { err "Can't continue without $ACCOUNTS_REPO."; exit 1; }
  npm_install "$ACCOUNTS_DIR" || exit 1
  pause
}

repos_servers_step() {
  step "2 of 5" "Pick the servers you want"
  local i
  SELECTED=()
  for i in "${!REPOS[@]}"; do
    if yes_key "Use ${BOLD}${REPO_LABELS[$i]}${RESET} (${REPOS[$i]})?"; then
      SELECTED+=("${REPOS[$i]}")
    fi
  done
  if [[ ${#SELECTED[@]} == 0 ]]; then
    warn "You didn't pick any servers. You can still connect accounts; run this again later to add servers."
    pause
    return
  fi
  say ""
  for i in "${SELECTED[@]}"; do
    if clone_or_update "$i" && npm_install "$BASE_DIR/$i"; then
      :
    else
      err "Skipping $i."
      SELECTED=($(printf '%s\n' "${SELECTED[@]}" | grep -vx "$i"))
    fi
  done
  pause
}

ensure_credentials() {
  [[ -f "$CREDENTIALS_PATH" ]] && check_client_json "$CREDENTIALS_PATH" && return 0
  warn "There's no OAuth client at $CREDENTIALS_PATH yet (that's section 1, step 5)."
  say "If you've already downloaded it, I'll find it now."
  install_credentials
}

auth() { (cd "$ACCOUNTS_DIR" && node auth.js "$@"); }

account_count() {
  node -e 'try { console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))).length); } catch { console.log(0); }' \
    "$GOOGLE_MCP_DIR/accounts.json"
}

add_nicknames() {
  local alias="$1" input part nick parts
  while true; do
    say ""
    say "Add nicknames for ${BOLD}$alias${RESET}? Type them separated by commas (e.g. ${BOLD}w, job${RESET})."
    say "Type ${BOLD}no${RESET} to move on. ${DIM}(only \"no\" moves on)${RESET}"
    read -r -p "> " input
    input=$(trim "$input")
    [[ "$(lower "$input")" == "no" ]] && return
    if [[ -z "$input" ]]; then
      say "Type one or more nicknames, or \"no\" to move on."
      continue
    fi
    IFS=',' read -ra parts <<<"$input"
    for part in "${parts[@]}"; do
      nick=$(trim "$part")
      [[ -z "$nick" ]] && continue
      if [[ ! "$nick" =~ $NAME_PATTERN ]]; then
        err "\"$nick\" isn't allowed. Use only letters, digits, - and _."
        continue
      fi
      auth --nick "$alias" "$nick"
    done
  done
}

connect_one() {
  local alias="$1" cancelled=0
  say ""
  say "Your browser will open a Google sign-in page. There:"
  say "  1. Pick (or sign in to) the Google account you want to call ${BOLD}$alias${RESET}."
  say "  2. On \"Google hasn't verified this app\", click ${BOLD}Continue${RESET} (sometimes under ${BOLD}Advanced${RESET})."
  say "  3. Leave ${BOLD}every permission ticked${RESET} and click ${BOLD}Continue${RESET}."
  say "  4. When the tab says \"Account connected\", come back here."
  say "${DIM}(Press Ctrl+C here to cancel this sign-in.)${RESET}"
  pause "Press any key to open the browser."
  trap 'cancelled=1' INT
  auth "$alias"
  local status=$?
  trap - INT
  if [[ "$cancelled" == 1 || "$status" != 0 ]]; then
    [[ "$cancelled" == 1 ]] && warn "Sign-in cancelled." || err "That account didn't connect."
    say "Common causes: the address isn't a test user (section 1, step 4), or you unticked a permission."
    return 1
  fi
}

connect_accounts() {
  local alias
  while true; do
    say ""
    say "Type an ${BOLD}alias${RESET} for the Google account to connect (e.g. ${BOLD}work${RESET}, ${BOLD}personal${RESET})."
    say "You'll then sign in to the account that alias should mean."
    say "Type ${BOLD}no${RESET} when you've connected them all. ${DIM}(only \"no\" moves on)${RESET}"
    read -r -p "> " alias
    alias=$(trim "$alias")
    if [[ "$(lower "$alias")" == "no" ]]; then
      if [[ "$(account_count)" == 0 ]]; then
        warn "No accounts are connected yet. Connect at least one first."
        continue
      fi
      return
    fi
    if [[ ! "$alias" =~ $NAME_PATTERN ]]; then
      err "Use only letters, digits, - and _ (e.g. work, personal-2)."
      continue
    fi
    connect_one "$alias" && add_nicknames "$alias"
  done
}

repos_connect_step() {
  step "3 of 5" "Connect your Google accounts"
  if ! ensure_credentials; then
    warn "Skipping this step. Run this again once you have the OAuth client file."
    pause
    return
  fi
  if [[ "$(account_count)" != 0 ]]; then
    say "Already connected:"
    auth --list
  fi
  connect_accounts
  pause
}

fix_accounts_menu() {
  local choice alias nick
  say ""
  say "What do you want to change?"
  say "  1) Connect another account (or re-connect one)"
  say "  2) Add nicknames"
  say "  3) Remove a nickname"
  say "  4) Remove an account"
  say "  5) Nothing, show the list again"
  read -r -p "> " choice
  case "$(trim "$choice")" in
    1) connect_accounts ;;
    2)
      read -r -p "Which account (alias)? " alias
      add_nicknames "$(trim "$alias")"
      ;;
    3)
      read -r -p "Which nickname? " nick
      auth --unnick "$(trim "$nick")"
      ;;
    4)
      read -r -p "Which alias? " alias
      auth --remove "$(trim "$alias")"
      ;;
  esac
}

repos_review_step() {
  step "4 of 5" "Check your accounts"
  local answer
  while true; do
    auth --list
    say "Each account's \"granted\" line should list gmail, calendar, calendarList, drive, docs, sheets and slides."
    say "If one is missing some, re-connect it with the same alias and leave every box ticked."
    say ""
    say "Is this list correct? Type ${BOLD}yes${RESET} to continue, or ${BOLD}no${RESET} to change something."
    read -r -p "> " answer
    case "$(lower "$(trim "$answer")")" in
      yes | y) break ;;
      no | n) fix_accounts_menu ;;
      *) say "Type yes or no." ;;
    esac
  done
  ok "Accounts confirmed."
  pause
}

# Prints (mode "print") or merges into Claude's config (mode "write") an
# mcpServers entry for each selected server.
claude_config() {
  node - "$1" "$CLAUDE_CONFIG" "$(command -v node)" "$BASE_DIR" "$FILES_DIR" "${SELECTED[@]}" <<'EOF'
const fs = require("fs");
const path = require("path");
const [mode, configPath, nodeBin, baseDir, filesDir, ...repos] = process.argv.slice(2);
const SERVERS = {
  "multi-gmail-mcp": ["multi-gmail", "MULTI_GMAIL_MCP_FILES_DIR"],
  "multi-gcal-mcp": ["multi-gcal", null],
  "multi-gdrive-mcp": ["multi-gdrive", "MULTI_GDRIVE_MCP_FILES_DIR"],
  "gworkspace-docs-sheets-slides-mcp": ["gworkspace-docs-sheets-slides", "GWORKSPACE_MCP_FILES_DIR"],
};
const entries = {};
for (const repo of repos) {
  const [key, envVar] = SERVERS[repo];
  entries[key] = { command: nodeBin, args: [path.join(baseDir, repo, "src", "server.js")] };
  if (envVar) entries[key].env = { [envVar]: filesDir };
}
if (mode === "print") {
  console.log(JSON.stringify({ mcpServers: entries }, null, 2));
  process.exit(0);
}
let config = {};
if (fs.existsSync(configPath)) {
  const raw = fs.readFileSync(configPath, "utf8");
  try {
    config = raw.trim() ? JSON.parse(raw) : {};
  } catch {
    console.error(`${configPath} isn't valid JSON, so it was left alone. Fix it or use the paste-a-prompt option.`);
    process.exit(1);
  }
  const backup = `${configPath}.backup-${new Date().toISOString().replace(/[:.]/g, "-")}`;
  fs.copyFileSync(configPath, backup);
  console.log(`Backed up your current config to ${backup}`);
}
const existing = config.mcpServers || {};
for (const [key, entry] of Object.entries(entries)) {
  // Keep any extra settings already added to this server's env.
  if (entry.env || existing[key]?.env) entry.env = { ...existing[key]?.env, ...entry.env };
}
config.mcpServers = { ...existing, ...entries };
fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
console.log(`Added ${Object.keys(entries).join(", ")} to ${configPath}`);
EOF
}

restart_claude() {
  if pgrep -x Claude >/dev/null; then
    osascript -e 'quit app "Claude"' 2>/dev/null
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      pgrep -x Claude >/dev/null || break
      sleep 1
    done
  fi
  open -a Claude && ok "Claude Desktop restarted."
}

claude_prompt() {
  cat <<EOF
Add these MCP servers to my Claude Desktop config at
~/Library/Application Support/Claude/claude_desktop_config.json.

- Back up the file first.
- Merge these entries into the existing "mcpServers" object. Keep every server
  that's already there; if one of these names already exists, replace it.
- If the file doesn't exist, create it with just this content.
- Make sure the result is valid JSON.
- Create the folder $FILES_DIR if it doesn't exist.

When you're done, tell me to fully quit Claude Desktop (Cmd+Q) and reopen it.

$(claude_config print)
EOF
}

repos_claude_step() {
  step "5 of 5" "Connect the servers to Claude"
  if [[ ${#SELECTED[@]} == 0 ]]; then
    warn "No servers were picked in step 2, so there's nothing to add to Claude."
    return
  fi

  say "The Gmail, Drive and Docs/Sheets/Slides servers share one folder for files they download or attach."
  local dir
  read -r -p "Files folder [$HOME/Downloads/google-mcp-files]: " dir
  FILES_DIR=$(clean_path "${dir:-$HOME/Downloads/google-mcp-files}")
  mkdir -p "$FILES_DIR" && chmod 700 "$FILES_DIR"

  local choice
  while true; do
    say ""
    say "How do you want to connect them?"
    say "  1) Do it for me: add them to Claude Desktop's config and restart Claude ${DIM}(recommended)${RESET}"
    say "  2) Give me a prompt to paste into Claude instead"
    read -r -p "> " choice
    case "$(trim "$choice")" in
      1 | 2) break ;;
      *) say "Type 1 or 2." ;;
    esac
  done

  if [[ "$choice" == 1 ]]; then
    claude_config write || return 1
    say ""
    if yes_key "Claude needs a full restart to load them. Quit and reopen Claude Desktop now?"; then
      restart_claude
    else
      say "Quit Claude with Cmd+Q (not just closing the window) and reopen it when you're ready."
    fi
  else
    local prompt
    prompt=$(claude_prompt)
    say ""
    say "${BOLD}Paste this into Claude Code (or any Claude that can edit files on this Mac):${RESET}"
    say "────────────────────────────────────────────────────────────────"
    say "$prompt"
    say "────────────────────────────────────────────────────────────────"
    printf '%s' "$prompt" | pbcopy && ok "It's also on your clipboard."
  fi

  say ""
  say "To check it worked: open a new chat in Claude Desktop, look for the servers under the tools icon,"
  say "and ask: ${BOLD}\"list my connected Google accounts\"${RESET}."
}

section_repos() {
  section_gate 2 "Repos, accounts and Claude" \
    "Clones the repos, connects each of your Google accounts, and adds the servers to Claude Desktop." ||
    return 0
  repos_accounts_step
  repos_servers_step
  repos_connect_step
  repos_review_step
  repos_claude_step
}

# --- Main ---------------------------------------------------------------------

main() {
  # When piped in (curl | bash), stdin is the script itself; read keys from the terminal.
  [[ -t 0 ]] || exec </dev/tty

  banner "Google MCP servers for Claude: guided setup"
  say "This walks you through everything, one step at a time. For each step it opens"
  say "the right page or runs the command for you, then waits for you before moving on."

  detect_accounts_dir
  check_assumptions
  section_google
  section_repos

  banner "All done"
  say "Heads up: while your Google app is in Testing mode, Google expires sign-ins after 7 days."
  say "When a server reports invalid_grant, re-connect that account:"
  say "  ${BOLD}cd \"${ACCOUNTS_DIR:-path/to/$ACCOUNTS_REPO}\" && node auth.js <alias>${RESET}"
  say ""
}

[[ -n "${SETUP_SH_NO_MAIN:-}" ]] || main "$@"
