#!/usr/bin/env bash
# Guided setup for the local Google MCP servers: Google Cloud project, OAuth
# client, cloning the repos, connecting accounts, and wiring it all into
# Claude Desktop. Runs on macOS, and on Windows in Git Bash (installed with
# Git for Windows).
#
# Safe to re-run: existing projects, clones, credentials, accounts and Claude
# config entries are reused or merged, never thrown away. Anything it replaces
# is backed up first.
#
# Run from a clone:   ./setup.sh
# Or without one:     bash <(curl -fsSL https://raw.githubusercontent.com/sharlenaluyen/google-mcp-accounts/main/setup.sh)

GH_OWNER="sharlenaluyen"
ACCOUNTS_REPO="google-mcp-accounts"
REPOS=(multi-gmail-mcp multi-gcal-mcp multi-gdrive-mcp gworkspace-docs-sheets-slides-mcp)
REPO_LABELS=("Gmail" "Google Calendar" "Google Drive" "Google Docs, Sheets & Slides")
APIS=(gmail.googleapis.com calendar-json.googleapis.com drive.googleapis.com docs.googleapis.com sheets.googleapis.com slides.googleapis.com)

case "$(uname -s)" in
  Darwin) OS=mac ;;
  MINGW* | MSYS* | CYGWIN*) OS=windows ;;
  *) OS=other ;;
esac

GOOGLE_MCP_DIR="${GOOGLE_MCP_DIR:-$HOME/.google-mcp}"
CREDENTIALS_PATH="$GOOGLE_MCP_DIR/credentials.json"
ACCOUNTS_PATH="$GOOGLE_MCP_DIR/accounts.json"
NAME_PATTERN='^[A-Za-z0-9_-]+$'

# Projects this script creates carry this label, so a re-run finds and reuses
# the project instead of making another one.
PROJECT_LABEL_KEY="created-by"
PROJECT_LABEL_VALUE="google-mcp-setup"
GCLOUD_SDK_DIR="$HOME/google-cloud-sdk"

GCLOUD=""
GCLOUD_ACCOUNT=""
PROJECT_ID=""
HAD_CREDENTIALS=0
BASE_DIR=""
ACCOUNTS_DIR=""
FILES_DIR=""
SELECTED=()
CLAUDE_EXE=""
CLOSED_CLAUDE=0

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

# Every prompt ends here if the terminal closes (or Ctrl+D), instead of
# reading empty answers forever.
input_ended() {
  printf '\n'
  err "Input ended, so setup stopped. Nothing half-done was left behind; run it again any time."
  exit 1
}

# Reads one key. Succeeds for Enter or Space, fails for any other key.
key_go() {
  local key
  IFS= read -rsn1 key || input_ended
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
  IFS= read -rsn1 _ || input_ended
  printf '\n'
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- Platform -----------------------------------------------------------------
# Git Bash's own commands use /c/Users/... paths; Windows programs (node,
# gcloud, Claude) and Claude's config need C:\Users\... ones.

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

open_url() {
  link "$1"
  if [[ "$OS" == mac ]]; then
    open "$1" 2>/dev/null
  else
    # Not cmd's start: it splits URLs at "&".
    rundll32.exe url.dll,FileProtocolHandler "$1" 2>/dev/null
  fi
}

copy_to_clipboard() { if [[ "$OS" == mac ]]; then pbcopy; else clip.exe; fi; }

file_mtime() { if [[ "$OS" == mac ]]; then stat -f '%Sm' "$1"; else date -r "$1" '+%b %e %H:%M:%S %Y'; fi; }

# Windows can move Downloads and Desktop (e.g. into OneDrive), so ask it.
DOWNLOADS_DIR="$HOME/Downloads"
DESKTOP_DIR="$HOME/Desktop"
if [[ "$OS" == windows ]]; then
  _folders=$(powershell.exe -NoProfile -Command "(New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path; [Environment]::GetFolderPath('Desktop')" 2>/dev/null | tr -d '\r')
  _downloads=$(sed -n 1p <<<"$_folders")
  _desktop=$(sed -n 2p <<<"$_folders")
  [[ -n "$_downloads" ]] && DOWNLOADS_DIR=$(cygpath -u "$_downloads")
  [[ -n "$_desktop" ]] && DESKTOP_DIR=$(cygpath -u "$_desktop")
fi

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

claude_installed() {
  if [[ "$OS" == mac ]]; then
    [[ -d /Applications/Claude.app || -d "$HOME/Applications/Claude.app" ]]
  else
    local packages=("$(unix_path "$LOCALAPPDATA")"/Packages/Claude_*)
    [[ -d "$(unix_path "$LOCALAPPDATA")/AnthropicClaude" || -d "${packages[0]}" ]] || claude_running
  fi
}

claude_running() {
  if [[ "$OS" == mac ]]; then
    pgrep -x Claude >/dev/null
  else
    tasklist.exe //FI "IMAGENAME eq claude.exe" //NH 2>/dev/null | grep -qi 'claude\.exe'
  fi
}

quit_claude() {
  claude_running || return 0
  if [[ "$OS" == mac ]]; then
    osascript -e 'quit app "Claude"' 2>/dev/null
  else
    # Remember where it runs from, to reopen the same install.
    CLAUDE_EXE=$(powershell.exe -NoProfile -Command '(Get-Process claude -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1).Path' 2>/dev/null | tr -d '\r')
    taskkill.exe //IM claude.exe //F >/dev/null 2>&1
  fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    claude_running || break
    sleep 1
  done
}

start_claude() {
  if [[ "$OS" == mac ]]; then
    open -a Claude && ok "Claude Desktop is open."
    return
  fi
  local exe="$CLAUDE_EXE"
  [[ -n "$exe" ]] || exe="$LOCALAPPDATA\\AnthropicClaude\\claude.exe"
  if powershell.exe -NoProfile -Command "Start-Process -FilePath '$exe'" >/dev/null 2>&1; then
    ok "Claude Desktop is open."
  else
    warn "Couldn't open Claude Desktop. Open it from the Start menu."
  fi
}

restart_claude() {
  quit_claude
  start_claude
}

if [[ "$OS" == mac ]]; then
  QUIT_CLAUDE_HINT="Quit Claude with Cmd+Q (not just closing the window)"
else
  QUIT_CLAUDE_HINT="Quit Claude from its icon in the system tray (right-click > Quit, not just closing the window)"
fi

# The first item's <field> from a JSON array on stdin (gcloud --format=json).
json_first() {
  node -e 'let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => { try { const v = JSON.parse(s)[0]; if (v && v[process.argv[1]]) console.log(v[process.argv[1]]); } catch {} });' "$1"
}

# A Console link, scoped to the project when we know its ID.
console_url() {
  local url="https://console.cloud.google.com/$1"
  if [[ -n "$PROJECT_ID" ]]; then
    [[ "$url" == *\?* ]] && url="$url&project=$PROJECT_ID" || url="$url?project=$PROJECT_ID"
  fi
  printf '%s' "$url"
}

timestamp() { date +%Y%m%d-%H%M%S; }

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

  if [[ "$OS" == other ]]; then
    if grep -qi microsoft /proc/version 2>/dev/null; then
      err "This is WSL. Run it in Git Bash instead (it comes with Git for Windows), so Claude can use it. Nothing was changed."
    else
      err "This script works on macOS, and on Windows in Git Bash. Nothing was changed."
    fi
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
    if [[ "$OS" == mac ]]; then
      say "Install Node.js 20 or newer (it includes npm) from https://nodejs.org, and git with: xcode-select --install"
    else
      say "Install Node.js 20 or newer (it includes npm) from https://nodejs.org, then open a new Git Bash window."
    fi
    exit 1
  fi
  if (($(node -p 'process.versions.node.split(".")[0]') < 20)); then
    err "Node.js $(node -v) is too old. Install version 20 or newer from https://nodejs.org"
    exit 1
  fi
  ok "git, Node.js $(node -v) and npm are installed."

  say "Checking that you can clone from GitHub over SSH..."
  until check_github_ssh; do
    err "GitHub SSH isn't working on this computer yet (git@github.com didn't accept your key)."
    say "Set it up with GitHub's guide:"
    link "https://docs.github.com/en/authentication/connecting-to-github-with-ssh"
    say ""
    say "  Press ENTER or SPACE to check again, any other key to quit."
    key_go || exit 0
  done
  ok "GitHub SSH works."

  if claude_installed; then
    ok "Claude Desktop is installed."
  else
    warn "Couldn't find Claude Desktop."
  fi
  say ""
  confirm_or_quit "Is Claude Desktop downloaded and are you signed in to it?"
  confirm_or_quit "Do you have more than one Google account, and are you signed in to all of them in your browser?"
  ok "All set."
}

# --- OAuth client file --------------------------------------------------------

# 0 = a Desktop app client, 2 = a Web application client, 1 = not a client file.
check_client_json() {
  node -e 'try { const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8").replace(/^\uFEFF/, "")); process.exit(j.installed ? 0 : j.web ? 2 : 1); } catch { process.exit(1); }' \
    "$(native_path "$1")"
}

has_credentials() { [[ -f "$CREDENTIALS_PATH" ]] && check_client_json "$CREDENTIALS_PATH"; }

# The project the installed OAuth client belongs to.
credentials_project_id() {
  node -e 'try { console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8").replace(/^\uFEFF/, "")).installed.project_id || ""); } catch {}' \
    "$(native_path "$CREDENTIALS_PATH")" | tr -d '\r'
}

# Newest Google OAuth client download in Downloads or Desktop.
find_client_json() {
  ls -t "$DOWNLOADS_DIR"/client_secret_*.json "$DESKTOP_DIR"/client_secret_*.json 2>/dev/null | head -1
}

# Finds the downloaded client JSON (waiting for it if needed) and moves it to
# ~/.google-mcp/credentials.json. An existing client is kept unless the user
# types "replace": swapping clients signs every connected account out.
install_credentials() {
  local src status answer
  if has_credentials; then
    ok "You already have an OAuth client at $CREDENTIALS_PATH, so there's nothing to do here."
    say "Replacing it with a different client signs out every connected account until you sign each in again."
    say ""
    say "  ${BOLD}Press ENTER${RESET} to keep it ${DIM}(recommended)${RESET}."
    say "  To swap in a new one, ${BOLD}type the word replace${RESET} and press ENTER."
    read -r -p "> " answer || input_ended
    [[ "$(lower "$(trim "$answer")")" == "replace" ]] || return 0
  fi

  while true; do
    src=$(find_client_json)
    if [[ -z "$src" ]]; then
      say "Waiting for the download (client_secret_....json) to show up in Downloads..."
      say "  ${DIM}(press any key to type the file's location instead)${RESET}"
      while [[ -z "$src" ]]; do
        IFS= read -rsn1 -t 2 _
        case $? in 0) break ;; 1) input_ended ;; esac
        src=$(find_client_json)
      done
    fi
    if [[ -n "$src" ]]; then
      say "Found: ${BOLD}$src${RESET}  ${DIM}(downloaded $(file_mtime "$src"))${RESET}"
      yes_key "Use this file?" || src=""
    fi
    if [[ -z "$src" ]]; then
      read -r -p "Drag the file into this window (or paste its path), then press Enter: " src || input_ended
      src=$(clean_path "$src")
    fi

    check_client_json "$src"
    status=$?
    if [[ "$status" == 0 ]]; then
      break
    elif [[ "$status" == 2 ]]; then
      err "That's a \"Web application\" client. Create a ${BOLD}Desktop app${RESET} client instead (section 1, step 5)."
    else
      err "\"$src\" isn't a Google OAuth client file."
    fi
    say "  Press ENTER or SPACE to try again, any other key to skip this for now."
    key_go || return 1
  done

  mkdir -p "$GOOGLE_MCP_DIR" && chmod 700 "$GOOGLE_MCP_DIR"
  if [[ -f "$CREDENTIALS_PATH" ]]; then
    local backup
    backup="$CREDENTIALS_PATH.backup-$(timestamp)"
    cp -p "$CREDENTIALS_PATH" "$backup" && ok "Backed up the old client to $backup."
  fi
  mv "$src" "$CREDENTIALS_PATH" && chmod 600 "$CREDENTIALS_PATH"
  ok "Moved it to $CREDENTIALS_PATH (readable only by you)."
}

# --- gcloud CLI ---------------------------------------------------------------

# A Python new enough for gcloud (3.10+), or nothing. Only needed on a Mac;
# the Windows download bundles its own.
find_python() {
  local py
  for py in python3.14 python3.13 python3.12 python3.11 python3.10 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    command -v "$py" >/dev/null 2>&1 || continue
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      command -v "$py"
      return 0
    fi
  done
  return 1
}

gcloud_works() { [[ -n "$GCLOUD" ]] && "$GCLOUD" --version >/dev/null 2>&1; }

# On Windows, gcloud.cmd: the bin/gcloud shell script there can't find the
# bundled Python.
find_gcloud() {
  local candidate candidates
  if [[ "$OS" == mac ]]; then
    candidates=("$(command -v gcloud)" "$GCLOUD_SDK_DIR/bin/gcloud" /opt/homebrew/bin/gcloud /usr/local/bin/gcloud)
  else
    candidates=("$(command -v gcloud.cmd)" "$GCLOUD_SDK_DIR/bin/gcloud.cmd"
      "$(unix_path "$LOCALAPPDATA")/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"
      "/c/Program Files (x86)/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"
      "/c/Program Files/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd")
  fi
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    GCLOUD="$candidate"
    gcloud_works && return 0
  done
  GCLOUD=""
  return 1
}

# Google's download, unpacked to ~/google-cloud-sdk. Its installer isn't run,
# so no shell config, PATH or system settings are touched.
download_gcloud() {
  local url tmp
  if [[ -e "$GCLOUD_SDK_DIR" ]]; then
    err "$GCLOUD_SDK_DIR exists but its gcloud doesn't run, so I'm leaving it alone."
    return 1
  fi
  tmp=$(mktemp -d)
  if [[ "$OS" == mac ]]; then
    local arch
    [[ "$(uname -m)" == "arm64" ]] && arch=arm || arch=x86_64
    url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-darwin-$arch.tar.gz"
    say "Downloading the gcloud CLI (about 55 MB) into $GCLOUD_SDK_DIR..."
    curl -fL --progress-bar "$url" | tar -xzf - -C "$tmp"
  else
    url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-windows-x86_64-bundled-python.zip"
    say "Downloading the gcloud CLI (about 100 MB, with its own Python) into $GCLOUD_SDK_DIR..."
    # Windows' own tar.exe unpacks zips; Git Bash's tar doesn't.
    curl -fL --progress-bar -o "$tmp/gcloud.zip" "$url" &&
      say "Unpacking..." &&
      /c/Windows/System32/tar.exe -xf "$(native_path "$tmp/gcloud.zip")" -C "$(native_path "$tmp")"
  fi
  if [[ $? == 0 ]] && mv "$tmp/google-cloud-sdk" "$GCLOUD_SDK_DIR"; then
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  err "The download didn't work."
  return 1
}

# Uses gcloud if it's already here, otherwise installs it (on a Mac, with
# Homebrew if you have it, else Google's download).
ensure_gcloud() {
  if find_gcloud; then
    ok "Using the gcloud CLI at $GCLOUD."
    return 0
  fi

  local python
  if [[ "$OS" == mac ]] && command -v brew >/dev/null; then
    say "I'll install Google's gcloud CLI with Homebrew and use it to create the project and turn on the APIs for you."
    yes_key "Install it now?" || return 1
    brew install --cask gcloud-cli || { err "Homebrew couldn't install gcloud."; return 1; }
  else
    if [[ "$OS" == mac ]]; then
      python=$(find_python)
      if [[ -z "$python" ]]; then
        warn "gcloud needs Python 3.10 or newer (or Homebrew to install it), and this Mac has neither."
        return 1
      fi
      export CLOUDSDK_PYTHON="$python"
    fi
    say "I'll download Google's gcloud CLI and use it to create the project and turn on the APIs for you."
    say "It goes in $GCLOUD_SDK_DIR and doesn't change any of your settings."
    yes_key "Download it now?" || return 1
    download_gcloud || return 1
  fi

  if find_gcloud; then
    ok "gcloud is installed: $GCLOUD"
    return 0
  fi
  err "gcloud is installed but doesn't start."
  return 1
}

g() { "$GCLOUD" --quiet "$@"; }

gcloud_active_account() { g auth list --filter=status:ACTIVE --format=json 2>/dev/null | json_first account | tr -d '\r'; }

gcloud_login() {
  local account
  account=$(gcloud_active_account)
  if [[ -n "$account" ]] && yes_key "gcloud is signed in as ${BOLD}$account${RESET}. Use this Google account to own the project?"; then
    GCLOUD_ACCOUNT="$account"
    return 0
  fi
  say "Your browser will open. Sign in with the Google account that should own the project"
  say "(any of yours; it doesn't have to be one you'll connect), then click ${BOLD}Allow${RESET}."
  pause "Press any key to open the browser."
  "$GCLOUD" auth login --brief || { err "gcloud sign-in didn't finish."; return 1; }
  GCLOUD_ACCOUNT=$(gcloud_active_account)
  [[ -n "$GCLOUD_ACCOUNT" ]] && ok "gcloud is signed in as $GCLOUD_ACCOUNT."
}

# Reuses the project an earlier run created, or creates one.
gcloud_project() {
  local id
  id=$(g projects list --filter="labels.$PROJECT_LABEL_KEY=$PROJECT_LABEL_VALUE" --format=json 2>/dev/null | json_first projectId | tr -d '\r')
  if [[ -n "$id" ]]; then
    PROJECT_ID="$id"
    ok "Reusing your project $id (created by an earlier run)."
    return 0
  fi
  id="google-mcp-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
  until g projects create "$id" --name=google-mcp --labels="$PROJECT_LABEL_KEY=$PROJECT_LABEL_VALUE"; do
    warn "Google didn't create the project. A new Google Cloud account first has to accept the Terms of Service."
    open_url "https://console.cloud.google.com/"
    say "Accept the terms on that page if it asks, then come back."
    say "  Press ENTER or SPACE to try again, any other key to do this step in the browser instead."
    key_go || return 1
  done
  PROJECT_ID="$id"
  ok "Created project $id."
}

# --- Section 1: Google Cloud --------------------------------------------------

google_project_step() {
  step "1 of 6" "Create a Google Cloud project"
  local id
  if [[ "$HAD_CREDENTIALS" == 1 ]]; then
    id=$(credentials_project_id)
    if [[ -n "$id" ]]; then
      PROJECT_ID="$id"
      ok "You already have a project: $id (your OAuth client belongs to it). Nothing to create."
      find_gcloud >/dev/null
      pause
      return
    fi
  fi

  if ensure_gcloud && gcloud_login && gcloud_project; then
    pause
    return
  fi

  warn "Let's do this step in the browser instead."
  say "Opening the Google Cloud \"New project\" page:"
  open_url "https://console.cloud.google.com/projectcreate"
  say ""
  say "  1. Project name: anything, e.g. ${BOLD}google-mcp${RESET}"
  say "  2. Organization / Location: leave as is (\"No organization\" is fine)."
  say "  3. Click ${BOLD}Create${RESET} and wait a few seconds for it to finish."
  say "${DIM}(If you made one on an earlier run, don't make another: just select it in the project picker.)${RESET}"
  pause "When the project is created, press any key."

  say ""
  say "Paste the project ${BOLD}ID${RESET} (shown under the project name, e.g. google-mcp-471203),"
  say "so the next links open straight to this project. Just press Enter to skip."
  read -r -p "> " id || input_ended
  id=$(trim "$id")
  if [[ "$id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    PROJECT_ID="$id"
    ok "Using project $PROJECT_ID."
  elif [[ -n "$id" ]]; then
    warn "That doesn't look like a project ID, so the links will open without one. Pick the project in the picker at the top of each page."
  else
    say "OK. On each page, make sure your project is selected in the picker at the top."
  fi
  pause
}

google_apis_step() {
  step "2 of 6" "Enable the Google APIs"
  # Enabling an API that's already on is a no-op, so this is safe to repeat.
  if [[ -n "$PROJECT_ID" ]] && gcloud_works && [[ -n "$(gcloud_active_account)" ]]; then
    say "Turning on the Gmail, Calendar, Drive, Docs, Sheets and Slides APIs in $PROJECT_ID..."
    if g services enable "${APIS[@]}" --project "$PROJECT_ID"; then
      ok "All six APIs are enabled."
      pause
      return
    fi
    warn "gcloud couldn't enable them (is it signed in as the project's owner?). Let's do it in the browser instead."
  fi

  local ids
  ids=$(IFS=,; printf '%s' "${APIS[*]}")
  say "Opening a page that enables all six APIs at once (Gmail, Calendar, Drive, Docs, Sheets, Slides):"
  open_url "$(console_url "flows/enableapi?apiid=$ids")"
  say ""
  say "  1. Check that your project is the one selected."
  say "  2. Click ${BOLD}Next${RESET}, then ${BOLD}Enable${RESET}."
  say ""
  say "${DIM}If that page doesn't work, go to APIs & Services → Library and enable each one by name.${RESET}"
  pause
}

google_consent_step() {
  step "3 of 6" "Set up the OAuth consent screen"
  if [[ "$HAD_CREDENTIALS" == 1 ]]; then
    ok "Already done: you have an OAuth client, and Google only lets you make one after this step."
    pause
    return
  fi
  local email="${GCLOUD_ACCOUNT:-your email}"
  say "Google doesn't let any tool do this part, so it's a few clicks. Opening Google Auth Platform:"
  open_url "$(console_url "auth/overview")"
  say ""
  say "  1. Click ${BOLD}Get started${RESET}."
  say "  2. App information: App name ${BOLD}Google MCP${RESET}, User support email ${BOLD}$email${RESET}. ${BOLD}Next${RESET}."
  say "  3. Audience: ${BOLD}External${RESET}. ${BOLD}Next${RESET}."
  say "  4. Contact information: ${BOLD}$email${RESET}. ${BOLD}Next${RESET}."
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
  say "     Addresses already on the list stay there; only add new ones."
  say "  3. Click ${BOLD}Save${RESET}."
  say ""
  say "Leave the app in ${BOLD}Testing${RESET}. Any address left off here gets \"Error 403: access_denied\" when it signs in."
  pause
}

google_client_step() {
  step "5 of 6" "Create the OAuth client and download it"
  if [[ "$HAD_CREDENTIALS" == 1 ]]; then
    ok "Already done: your OAuth client is at $CREDENTIALS_PATH."
    pause
    return
  fi
  say "Google doesn't let any tool do this part either. Opening the \"Create client\" page:"
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
  has_credentials && HAD_CREDENTIALS=1
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
    # --ff-only never merges or discards anything; with local changes it just stops.
    git -C "$dest" pull --ff-only || warn "Couldn't update $repo (local changes?). Using it as it is."
  elif [[ -e "$dest" ]]; then
    err "$dest already exists and isn't a git repo, so I'm leaving it alone."
    return 1
  else
    git clone "git@github.com:$GH_OWNER/$repo.git" "$dest" || return 1
  fi
}

# npm ci installs exactly what's in package-lock.json and never rewrites it,
# so re-running doesn't leave changes in the repo.
npm_install() {
  local name
  name=$(basename "$1")
  say "Installing $name's dependencies..."
  (cd "$1" && { npm ci --no-fund --no-audit || npm install --no-fund --no-audit; }) ||
    { err "npm install failed in $1"; return 1; }
  ok "$name is installed."
}

repos_accounts_step() {
  step "1 of 5" "Get google-mcp-accounts"
  # Windows won't let npm replace files a running server has open, so Claude
  # (which runs the servers) has to be closed first.
  if [[ "$OS" == windows ]] && claude_running; then
    say "Claude Desktop is running. It has to be closed while the servers install, or Windows blocks the update."
    if yes_key "Close Claude Desktop now? (It reopens at the end.)"; then
      quit_claude
      CLOSED_CLAUDE=1
      ok "Closed Claude Desktop."
    else
      warn "Leaving it open. If an install fails with EBUSY or EPERM, close Claude and run this again."
    fi
  fi

  if [[ -n "$ACCOUNTS_DIR" ]]; then
    ok "You're running this from $ACCOUNTS_DIR, so the servers go next to it in $BASE_DIR."
  else
    # Default to wherever an earlier run put the repos.
    local dir default
    default=$(unix_path "$(claude_config existing-base)")
    [[ -n "$default" ]] || default="$HOME/google-mcp"
    say "Where should the repos go? Press Enter for the default."
    read -r -p "Folder [$default]: " dir || input_ended
    dir=$(clean_path "${dir:-$default}")
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
  local i repo
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
  for repo in "${SELECTED[@]}"; do
    if ! { clone_or_update "$repo" && npm_install "$BASE_DIR/$repo"; }; then
      err "Skipping $repo."
      SELECTED=($(printf '%s\n' "${SELECTED[@]}" | grep -vx "$repo"))
    fi
  done
  pause
}

ensure_credentials() {
  has_credentials && return 0
  warn "There's no OAuth client at $CREDENTIALS_PATH yet (that's section 1, step 5)."
  say "If you've already downloaded it, I'll find it now."
  install_credentials
}

auth() { (cd "$ACCOUNTS_DIR" && node auth.js "$@"); }

account_count() {
  node -e 'try { console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))).length); } catch { console.log(0); }' \
    "$(native_path "$ACCOUNTS_PATH")" | tr -d '\r'
}

# The address an alias or nickname is connected to, or nothing.
account_email() {
  node -e '
    try {
      const accounts = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const name = process.argv[2];
      const alias = Object.hasOwn(accounts, name)
        ? name
        : Object.keys(accounts).find((a) => (accounts[a].nicknames || []).includes(name));
      if (alias) console.log(accounts[alias].email);
    } catch {}' "$(native_path "$ACCOUNTS_PATH")" "$1" | tr -d '\r'
}

add_nicknames() {
  local alias="$1" input part nick parts
  while true; do
    say ""
    say "Add nicknames for ${BOLD}$alias${RESET}? Type them separated by commas (e.g. ${BOLD}w, job${RESET})."
    say "Press ${BOLD}ENTER${RESET} (or type ${BOLD}no${RESET}) to move on without adding any."
    read -r -p "> " input || input_ended
    input=$(trim "$input")
    [[ -z "$input" || "$(lower "$input")" == "no" ]] && return
    IFS=',' read -ra parts <<<"$input"
    for part in "${parts[@]}"; do
      nick=$(trim "$part")
      [[ -z "$nick" ]] && continue
      if [[ ! "$nick" =~ $NAME_PATTERN ]]; then
        err "\"$nick\" isn't allowed. Use only letters, digits, - and _."
      elif [[ -n "$(account_email "$nick")" && "$(account_email "$nick")" == "$(account_email "$alias")" ]]; then
        ok "\"$nick\" already points to $alias."
      else
        auth --nick "$alias" "$nick"
      fi
    done
  done
}

connect_one() {
  local alias="$1" before="$2" cancelled=0 status after
  say ""
  say "Your browser will open a Google sign-in page. There:"
  say "  1. Pick (or sign in to) the Google account you want to call ${BOLD}$alias${RESET}${before:+ (${BOLD}$before${RESET})}."
  say "  2. On \"Google hasn't verified this app\", click ${BOLD}Continue${RESET} (sometimes under ${BOLD}Advanced${RESET})."
  say "  3. Leave ${BOLD}every permission ticked${RESET} and click ${BOLD}Continue${RESET}."
  say "  4. When the tab says \"Account connected\", come back here."
  say "${DIM}(Press Ctrl+C here to cancel this sign-in.)${RESET}"
  pause "Press any key to open the browser."
  trap 'cancelled=1' INT
  auth "$alias"
  status=$?
  trap - INT
  if [[ "$cancelled" == 1 || "$status" != 0 ]]; then
    [[ "$cancelled" == 1 ]] && warn "Sign-in cancelled." || err "That account didn't connect."
    say "Common causes: the address isn't a test user (section 1, step 4), or you unticked a permission."
    return 1
  fi
  after=$(account_email "$alias")
  if [[ -n "$before" && "$after" != "$before" ]]; then
    warn "\"$alias\" used to be $before and is now $after."
    say "If that's not what you wanted, run this step again with alias $alias and sign in as $before."
  fi
}

connect_accounts() {
  local alias email
  while true; do
    say ""
    say "Type an ${BOLD}alias${RESET} for the Google account to connect (e.g. ${BOLD}work${RESET}, ${BOLD}personal${RESET})."
    say "You'll then sign in to the account that alias should mean."
    say "Press ${BOLD}ENTER${RESET} (or type ${BOLD}no${RESET}) when you've connected them all; nothing changes."
    read -r -p "> " alias || input_ended
    alias=$(trim "$alias")
    if [[ -z "$alias" || "$(lower "$alias")" == "no" ]]; then
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
    email=$(account_email "$alias")
    if [[ -n "$email" ]]; then
      say "\"$alias\" is already connected to ${BOLD}$email${RESET}."
      yes_key "Sign in to it again to refresh it? (Sign in as $email; a different account would take over this alias.)" ||
        continue
    fi
    connect_one "$alias" "$email" && add_nicknames "$alias"
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
    say "Already connected (these stay as they are unless you re-connect one):"
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
  read -r -p "> " choice || input_ended
  case "$(trim "$choice")" in
    1) connect_accounts ;;
    2)
      read -r -p "Which account (alias)? " alias || input_ended
      add_nicknames "$(trim "$alias")"
      ;;
    3)
      read -r -p "Which nickname? " nick || input_ended
      auth --unnick "$(trim "$nick")"
      ;;
    4)
      read -r -p "Which alias? " alias || input_ended
      alias=$(trim "$alias")
      yes_key "Remove \"$alias\" ($(account_email "$alias"))? You'd have to sign in again to get it back." &&
        auth --remove "$alias"
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
    say "Is this list correct? Press ${BOLD}ENTER${RESET} (or type ${BOLD}yes${RESET}) if it is, or type ${BOLD}no${RESET} to change something."
    read -r -p "> " answer || input_ended
    case "$(lower "$(trim "$answer")")" in
      "" | yes | y) break ;;
      no | n) fix_accounts_menu ;;
      *) say "Press ENTER if it's correct, or type no." ;;
    esac
  done
  ok "Accounts confirmed."
  pause
}

# The node binary Claude should launch. On Windows, the full node.exe path.
node_bin() {
  local bin
  bin=$(command -v node)
  [[ "$OS" == windows && -f "$bin.exe" ]] && bin="$bin.exe"
  native_path "$bin"
}

# Claude Desktop config helper. Modes:
#   print          the mcpServers entries for the selected servers, as JSON
#   write          merge them into Claude's config (exits 3 if nothing changed)
#   existing-base  the folder an earlier run put the servers in
#   existing-files the shared files folder an earlier run set
claude_config() {
  local base="" files=""
  [[ -n "$BASE_DIR" ]] && base=$(native_path "$BASE_DIR")
  [[ -n "$FILES_DIR" ]] && files=$(native_path "$FILES_DIR")
  node - "$1" "$(native_path "$CLAUDE_CONFIG")" "$(node_bin)" "$base" "$files" "${SELECTED[@]}" <<'EOF' | tr -d '\r'
const fs = require("fs");
const path = require("path");
const [mode, configPath, nodeBin, baseDir, filesDir, ...repos] = process.argv.slice(2);
const SERVERS = {
  "multi-gmail-mcp": ["multi-gmail", "MULTI_GMAIL_MCP_FILES_DIR"],
  "multi-gcal-mcp": ["multi-gcal", null],
  "multi-gdrive-mcp": ["multi-gdrive", "MULTI_GDRIVE_MCP_FILES_DIR"],
  "gworkspace-docs-sheets-slides-mcp": ["gworkspace-docs-sheets-slides", "GWORKSPACE_MCP_FILES_DIR"],
};

let raw = "";
let config = {};
if (fs.existsSync(configPath)) {
  // Windows editors sometimes save a byte-order mark JSON.parse rejects.
  raw = fs.readFileSync(configPath, "utf8").replace(/^\uFEFF/, "");
  try {
    config = raw.trim() ? JSON.parse(raw) : {};
  } catch {
    if (mode.startsWith("existing")) process.exit(0);
    console.error(`${configPath} isn't valid JSON, so it was left alone. Fix it or use the paste-a-prompt option.`);
    process.exit(1);
  }
}
const existing = config.mcpServers || {};

if (mode.startsWith("existing")) {
  const found = Object.values(SERVERS)
    .map(([key, envVar]) => {
      const entry = existing[key];
      if (mode === "existing-base") return entry?.args?.[0] && path.resolve(entry.args[0], "../../..");
      return envVar && entry?.env?.[envVar];
    })
    .find(Boolean);
  if (found) console.log(found);
  process.exit(0);
}

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

for (const [key, entry] of Object.entries(entries)) {
  // Keep any other settings already on this server: its other env vars and fields.
  const old = existing[key] || {};
  const env = { ...old.env, ...entry.env };
  entries[key] = { ...old, ...entry, ...(Object.keys(env).length && { env }) };
}
config.mcpServers = { ...existing, ...entries };
const updated = JSON.stringify(config, null, 2) + "\n";
if (raw && JSON.stringify(JSON.parse(raw)) === JSON.stringify(config)) {
  console.log(`Claude's config already has ${Object.keys(entries).join(", ")}, so nothing changed.`);
  process.exit(3);
}
if (raw) {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
  fs.copyFileSync(configPath, `${configPath}.backup-${stamp}`);
  console.log(`Backed up your current config to ${configPath}.backup-${stamp}`);
}
fs.mkdirSync(path.dirname(configPath), { recursive: true });
// Write a temp file and rename it, so Claude never sees a half-written config.
const tmp = `${configPath}.${process.pid}.tmp`;
fs.writeFileSync(tmp, updated);
fs.renameSync(tmp, configPath);
console.log(`Added ${Object.keys(entries).join(", ")} to ${configPath}`);
EOF
  return "${PIPESTATUS[0]}"
}

claude_prompt() {
  cat <<EOF
Add these MCP servers to my Claude Desktop config at
$(native_path "$CLAUDE_CONFIG")

- Back up the file first.
- Merge these entries into the existing "mcpServers" object. Keep every server
  that's already there; if one of these names already exists, replace its
  "command" and "args" and merge its "env", keeping any other settings on it.
- If the file doesn't exist, create it with just this content.
- Make sure the result is valid JSON.
- Create the folder $(native_path "$FILES_DIR") if it doesn't exist.

When you're done, tell me to fully quit Claude Desktop and reopen it.

$(claude_config print)
EOF
}

repos_claude_step() {
  step "5 of 5" "Connect the servers to Claude"
  if [[ ${#SELECTED[@]} == 0 ]]; then
    warn "No servers were picked in step 2, so there's nothing to add to Claude."
    return
  fi

  local dir default
  default=$(unix_path "$(claude_config existing-files)")
  [[ -n "$default" ]] || default="$DOWNLOADS_DIR/google-mcp-files"
  say "The Gmail, Drive and Docs/Sheets/Slides servers share one folder for files they download or attach."
  read -r -p "Files folder [$default]: " dir || input_ended
  FILES_DIR=$(clean_path "${dir:-$default}")
  # Only lock down a folder this script creates; never change an existing one.
  if [[ ! -d "$FILES_DIR" ]]; then
    mkdir -p "$FILES_DIR" && chmod 700 "$FILES_DIR"
  fi

  local choice
  while true; do
    say ""
    say "How do you want to connect them?"
    say "  1) Do it for me: add them to Claude Desktop's config and restart Claude ${DIM}(recommended)${RESET}"
    say "  2) Give me a prompt to paste into Claude instead"
    read -r -p "> " choice || input_ended
    case "$(trim "$choice")" in
      1 | 2) break ;;
      *) say "Type 1 or 2." ;;
    esac
  done

  if [[ "$choice" == 1 ]]; then
    claude_config write
    case $? in
      0)
        say ""
        if yes_key "Claude needs a full restart to load them. Quit and reopen Claude Desktop now?"; then
          restart_claude
        else
          say "$QUIT_CLAUDE_HINT and reopen it when you're ready."
        fi
        CLOSED_CLAUDE=0 # answered here, so it isn't reopened again at the end
        ;;
      3) ;;
      *) return 1 ;;
    esac
  else
    local prompt
    prompt=$(claude_prompt)
    say ""
    say "${BOLD}Paste this into Claude Code (or any Claude that can edit files on this computer):${RESET}"
    say "────────────────────────────────────────────────────────────────"
    say "$prompt"
    say "────────────────────────────────────────────────────────────────"
    printf '%s' "$prompt" | copy_to_clipboard && ok "It's also on your clipboard."
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
  say "This walks you through everything, one step at a time. For each step it does the work"
  say "itself or opens the right page, then waits for you before moving on."
  say "It's safe to run again: what's already set up is reused, never replaced without asking."

  detect_accounts_dir
  check_assumptions
  section_google
  section_repos

  # Claude was closed for the install in section 2, and nothing reopened it.
  if [[ "$CLOSED_CLAUDE" == 1 ]] && ! claude_running; then
    start_claude
  fi

  banner "All done"
  say "Heads up: while your Google app is in Testing mode, Google expires sign-ins after 7 days."
  say "When that happens, run refresh-tokens.sh, or re-connect one account with:"
  say "  ${BOLD}cd \"${ACCOUNTS_DIR:-path/to/$ACCOUNTS_REPO}\" && node auth.js <alias>${RESET}"
  say ""
}

# exit right after main, so a git pull that updates this file mid-run can't
# make bash read the rest of a changed file.
[[ -n "${SETUP_SH_NO_MAIN:-}" ]] || { main "$@"; exit $?; }
