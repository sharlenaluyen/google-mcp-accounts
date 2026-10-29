# Guided setup for the local Google MCP servers on Windows: Google Cloud
# project, OAuth client, cloning the repos, connecting accounts, and wiring it
# all into Claude Desktop. The Windows version of setup-mac.sh.
#
# Safe to re-run: existing projects, clones, credentials, accounts and Claude
# config entries are reused or merged, never thrown away. Anything it replaces
# is backed up first.
#
# Run from a clone (in PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
# Or without one:
#   irm https://raw.githubusercontent.com/sharlenaluyen/google-mcp-accounts/main/setup-windows.ps1 | iex
#
# Kept to plain ASCII and Windows PowerShell 5.1 syntax, so it runs on a
# stock Windows 10/11 without PowerShell 7.

$ErrorActionPreference = 'Continue'
$ScriptDir = $PSScriptRoot # empty when run through irm | iex

$GhOwner = 'sharlenaluyen'
$AccountsRepo = 'google-mcp-accounts'
$Repos = @(
  @{ Name = 'multi-gmail-mcp'; Label = 'Gmail' },
  @{ Name = 'multi-gcal-mcp'; Label = 'Google Calendar' },
  @{ Name = 'multi-gdrive-mcp'; Label = 'Google Drive' },
  @{ Name = 'gworkspace-docs-sheets-slides-mcp'; Label = 'Google Docs, Sheets & Slides' }
)
$Apis = @('gmail.googleapis.com', 'calendar-json.googleapis.com', 'drive.googleapis.com',
  'docs.googleapis.com', 'sheets.googleapis.com', 'slides.googleapis.com')

$GoogleMcpDir = if ($env:GOOGLE_MCP_DIR) { $env:GOOGLE_MCP_DIR } else { Join-Path $HOME '.google-mcp' }
$CredentialsPath = Join-Path $GoogleMcpDir 'credentials.json'
$AccountsPath = Join-Path $GoogleMcpDir 'accounts.json'
$NamePattern = '^[A-Za-z0-9_-]+$'

# Projects this script creates carry this label, so a re-run finds and reuses
# the project instead of making another one.
$ProjectLabelKey = 'created-by'
$ProjectLabelValue = 'google-mcp-setup'
$GcloudSdkDir = Join-Path $HOME 'google-cloud-sdk'
$GcloudZipUrl = 'https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-windows-x86_64-bundled-python.zip'

$Node = $null
$Gcloud = $null
$GcloudAccount = ''
$ProjectId = ''
$HadCredentials = $false
$BaseDir = ''
$AccountsDir = ''
$FilesDir = ''
$Selected = @()

$ClosedClaude = $false

# Thrown to end setup. A plain `exit` would close the whole PowerShell window
# when the script is run through irm | iex.
function Stop-Setup([string]$Message) { throw [System.OperationCanceledException]::new($Message) }

# --- Output -------------------------------------------------------------------

function Say([string]$Text = '') { Write-Host $Text }
function Ok([string]$Text) { Write-Host '[ok] ' -ForegroundColor Green -NoNewline; Write-Host $Text }
function Warn([string]$Text) { Write-Host '[!] ' -ForegroundColor Yellow -NoNewline; Write-Host $Text }
function Err([string]$Text) { Write-Host '[x] ' -ForegroundColor Red -NoNewline; Write-Host $Text }
function Dim([string]$Text) { Write-Host $Text -ForegroundColor DarkGray }
function Link([string]$Url) { Write-Host "  $Url" -ForegroundColor Cyan }

function Banner([string]$Title) {
  $line = '=' * 62
  Write-Host ''
  Write-Host $line -ForegroundColor White
  Write-Host "  $Title" -ForegroundColor White
  Write-Host $line -ForegroundColor White
  Write-Host ''
}

function Step([string]$Number, [string]$Title) {
  Write-Host ''
  Write-Host "-- Step ${Number}: $Title" -ForegroundColor White
  Write-Host ''
}

# --- Input --------------------------------------------------------------------

function Read-Line([string]$Prompt = '>') {
  Write-Host "$Prompt " -NoNewline
  $line = [Console]::ReadLine()
  if ($null -eq $line) { Stop-Setup 'Input ended, so setup stopped. Run it again any time.' }
  return $line.Trim()
}

# Reads one key. True for Enter or Space, false for any other key.
function Read-GoKey {
  $key = [Console]::ReadKey($true)
  Write-Host ''
  return ($key.Key -eq 'Enter' -or $key.Key -eq 'Spacebar')
}

# Asks before a section: Enter/Space runs it, any other key skips it.
function Confirm-Section([string]$Number, [string]$Title, [string]$Summary) {
  Banner "Section ${Number}: $Title"
  Say $Summary
  Say
  Write-Host '  Press ENTER or SPACE' -ForegroundColor White -NoNewline; Say ' to start this section.'
  Write-Host '  Press ANY OTHER KEY' -ForegroundColor White -NoNewline; Say ' to skip it.'
  return (Read-GoKey)
}

# Enter/Space = yes, any other key = no.
function Confirm-Key([string]$Question) {
  Say $Question
  Dim '  (ENTER or SPACE = yes, any other key = no)'
  return (Read-GoKey)
}

function Wait-Key([string]$Message = "When you're done, press any key for the next step.") {
  Write-Host ''
  Write-Host "$Message " -ForegroundColor DarkGray -NoNewline
  [void][Console]::ReadKey($true)
  Write-Host ''
}

# A path typed, pasted, or dragged in (which wraps it in quotes).
function Clean-Path([string]$Path) {
  $p = $Path.Trim().Trim('"').Trim("'")
  if ($p.StartsWith('~')) { $p = $HOME + $p.Substring(1) }
  return $p
}

function Get-ConsoleUrl([string]$Path) {
  $url = "https://console.cloud.google.com/$Path"
  if ($script:ProjectId) {
    if ($url.Contains('?')) { $url += "&project=$($script:ProjectId)" } else { $url += "?project=$($script:ProjectId)" }
  }
  return $url
}

function Open-Url([string]$Url) {
  Link $Url
  Start-Process $Url
}

function Get-Timestamp { return (Get-Date).ToString('yyyyMMdd-HHmmss') }

# --- Running node -------------------------------------------------------------

# Runs JavaScript fed through stdin, with inputs passed as environment
# variables (Windows PowerShell 5.1 mangles quotes and drops empty strings
# in native-command arguments). Returns its output lines; $LASTEXITCODE is
# the script's exit code.
function Invoke-Node([string]$Code, [hashtable]$Vars = @{}) {
  foreach ($name in $Vars.Keys) { Set-Item "env:$name" ([string]$Vars[$name]) }
  try {
    return ($Code | & $script:Node -)
  } finally {
    foreach ($name in $Vars.Keys) { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
  }
}

# node auth.js with its output shown on screen; returns the exit code.
function Invoke-Auth([string[]]$AuthArgs) {
  Push-Location $script:AccountsDir
  try {
    & $script:Node auth.js @AuthArgs | Out-Host
    return $LASTEXITCODE
  } finally {
    Pop-Location
  }
}

# --- Claude Desktop -----------------------------------------------------------

# The Microsoft Store build of Claude keeps its config in its package folder
# once it has written one there; the regular installer uses %APPDATA%.
function Get-ClaudeConfigPath {
  $packages = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue
  foreach ($package in $packages) {
    $candidate = Join-Path $package.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json'
    if (Test-Path $candidate) { return $candidate }
  }
  return (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json')
}
$ClaudeConfig = Get-ClaudeConfigPath

function Test-ClaudeInstalled {
  if (Test-Path (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')) { return $true }
  if (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue) { return $true }
  return [bool](Get-Process -Name 'claude' -ErrorAction SilentlyContinue)
}

function Test-ClaudeRunning { return [bool](Get-Process -Name 'claude' -ErrorAction SilentlyContinue) }

function Stop-Claude {
  $procs = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
  if (-not $procs) { return $null }
  $exe = ($procs | Where-Object { $_.Path } | Select-Object -First 1).Path
  $procs | Stop-Process -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 15 -and (Test-ClaudeRunning); $i++) { Start-Sleep -Seconds 1 }
  return $exe
}

function Restart-Claude {
  $exe = Stop-Claude
  if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe' }
  try {
    Start-Process $exe -ErrorAction Stop
    Ok 'Claude Desktop restarted.'
  } catch {
    Warn 'Closed Claude Desktop, but couldn''t reopen it. Open it from the Start menu.'
  }
}

# Claude Desktop config helper. Modes:
#   print          the mcpServers entries for the selected servers, as JSON
#   write          merge them into Claude's config (exits 3 if nothing changed)
#   existing-base  the folder an earlier run put the servers in
#   existing-files the shared files folder an earlier run set
$ClaudeConfigJs = @'
const fs = require("fs");
const path = require("path");
const env = process.env;
const mode = env.GMCP_MODE;
const configPath = env.GMCP_CONFIG;
const repos = (env.GMCP_REPOS || "").split(",").filter(Boolean);
const SERVERS = {
  "multi-gmail-mcp": ["multi-gmail", "MULTI_GMAIL_MCP_FILES_DIR"],
  "multi-gcal-mcp": ["multi-gcal", null],
  "multi-gdrive-mcp": ["multi-gdrive", "MULTI_GDRIVE_MCP_FILES_DIR"],
  "gworkspace-docs-sheets-slides-mcp": ["gworkspace-docs-sheets-slides", "GWORKSPACE_MCP_FILES_DIR"],
};

let raw = "";
let config = {};
if (fs.existsSync(configPath)) {
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
  entries[key] = { command: env.GMCP_NODE, args: [path.join(env.GMCP_BASE, repo, "src", "server.js")] };
  if (envVar) entries[key].env = { [envVar]: env.GMCP_FILES };
}
if (mode === "print") {
  console.log(JSON.stringify({ mcpServers: entries }, null, 2));
  process.exit(0);
}

for (const [key, entry] of Object.entries(entries)) {
  // Keep any other settings already on this server: its other env vars and fields.
  const old = existing[key] || {};
  const merged = { ...old.env, ...entry.env };
  entries[key] = { ...old, ...entry, ...(Object.keys(merged).length && { env: merged }) };
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
'@

function Invoke-ClaudeConfig([string]$Mode) {
  return (Invoke-Node $ClaudeConfigJs @{
      GMCP_MODE   = $Mode
      GMCP_CONFIG = $script:ClaudeConfig
      GMCP_NODE   = $script:Node
      GMCP_BASE   = $script:BaseDir
      GMCP_FILES  = $script:FilesDir
      GMCP_REPOS  = ($script:Selected -join ',')
    })
}

# --- Assumptions --------------------------------------------------------------

function Confirm-OrQuit([string]$Question) {
  Say $Question
  Dim '  (ENTER or SPACE = yes, any other key = quit setup)'
  if (-not (Read-GoKey)) { Stop-Setup "Come back and run this again once that's sorted." }
}

function Test-GithubSsh {
  & git ls-remote "git@github.com:$GhOwner/$AccountsRepo.git" HEAD | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Test-Assumptions {
  Banner 'Before we start'

  if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Stop-Setup 'This script is for Windows. On a Mac, use setup-mac.sh. Nothing was changed.'
  }

  $missing = $false
  foreach ($tool in 'git', 'node', 'npm') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Err "$tool isn't installed."; $missing = $true }
  }
  if ($missing) {
    Say 'Install Node.js 20 or newer (it includes npm) from https://nodejs.org and Git from https://git-scm.com,'
    Stop-Setup 'then open a new PowerShell window and run this again.'
  }
  $script:Node = (Get-Command node).Source
  $major = [int]((& $script:Node --version).TrimStart('v').Split('.')[0])
  if ($major -lt 20) { Stop-Setup "Node.js $(& $script:Node --version) is too old. Install version 20 or newer from https://nodejs.org" }
  Ok "git, Node.js $(& $script:Node --version) and npm are installed."

  Say 'Checking that you can clone from GitHub over SSH...'
  Dim '(If it asks whether to trust github.com, type yes.)'
  while (-not (Test-GithubSsh)) {
    Err 'GitHub SSH isn''t working on this PC yet (git@github.com didn''t accept your key).'
    Say 'Set it up with GitHub''s guide:'
    Link 'https://docs.github.com/en/authentication/connecting-to-github-with-ssh'
    Say
    Say '  Press ENTER or SPACE to check again, any other key to quit.'
    if (-not (Read-GoKey)) { Stop-Setup 'Come back once GitHub SSH works.' }
  }
  Ok 'GitHub SSH works.'

  if (Test-ClaudeInstalled) { Ok 'Claude Desktop is installed.' } else { Warn 'Couldn''t find Claude Desktop.' }
  Say
  Confirm-OrQuit 'Is Claude Desktop downloaded and are you signed in to it?'
  Confirm-OrQuit 'Do you have more than one Google account, and are you signed in to all of them in your browser?'
  Ok 'All set.'
}

# --- OAuth client file --------------------------------------------------------

# 0 = a Desktop app client, 2 = a Web application client, 1 = not a client file.
function Test-ClientJson([string]$Path) {
  [void](Invoke-Node @'
try {
  const j = JSON.parse(require("fs").readFileSync(process.env.GMCP_FILE, "utf8").replace(/^\uFEFF/, ""));
  process.exit(j.installed ? 0 : j.web ? 2 : 1);
} catch {
  process.exit(1);
}
'@ @{ GMCP_FILE = $Path })
  return $LASTEXITCODE
}

function Test-Credentials { return ((Test-Path $CredentialsPath) -and (Test-ClientJson $CredentialsPath) -eq 0) }

# The project the installed OAuth client belongs to.
function Get-CredentialsProjectId {
  return (Invoke-Node @'
try {
  console.log(JSON.parse(require("fs").readFileSync(process.env.GMCP_FILE, "utf8").replace(/^\uFEFF/, "")).installed.project_id || "");
} catch {}
'@ @{ GMCP_FILE = $CredentialsPath })
}

function Get-DownloadsDir {
  try {
    $path = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
    if ($path -and (Test-Path $path)) { return $path }
  } catch {}
  return (Join-Path $HOME 'Downloads')
}

# Newest Google OAuth client download in Downloads or Desktop.
function Find-ClientJson {
  $dirs = @((Get-DownloadsDir), [Environment]::GetFolderPath('Desktop'))
  $file = Get-ChildItem -Path $dirs -Filter 'client_secret_*.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($file) { return $file.FullName }
  return $null
}

# Finds the downloaded client JSON (waiting for it if needed) and moves it to
# ~\.google-mcp\credentials.json. An existing client is kept unless the user
# types "replace": swapping clients signs every connected account out.
function Install-Credentials {
  if (Test-Credentials) {
    Ok "You already have an OAuth client at $CredentialsPath, so there's nothing to do here."
    Say 'Replacing it with a different client signs out every connected account until you sign each in again.'
    Say
    Write-Host '  Press ENTER' -ForegroundColor White -NoNewline; Say ' to keep it (recommended).'
    Write-Host '  To swap in a new one, ' -NoNewline; Write-Host 'type the word replace' -ForegroundColor White -NoNewline; Say ' and press ENTER.'
    if ((Read-Line).ToLower() -ne 'replace') { return $true }
  }

  while ($true) {
    $src = Find-ClientJson
    if (-not $src) {
      Say 'Waiting for the download (client_secret_....json) to show up in Downloads...'
      Dim '  (press any key to type the file''s location instead)'
      while (-not $src) {
        if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); break }
        Start-Sleep -Seconds 1
        $src = Find-ClientJson
      }
    }
    if ($src) {
      Write-Host 'Found: ' -NoNewline; Write-Host $src -ForegroundColor White -NoNewline
      Dim "  (downloaded $((Get-Item $src).LastWriteTime))"
      if (-not (Confirm-Key 'Use this file?')) { $src = $null }
    }
    if (-not $src) {
      $src = Clean-Path (Read-Line 'Drag the file into this window (or paste its path), then press Enter:')
    }

    $status = Test-ClientJson $src
    if ($status -eq 0) { break }
    if ($status -eq 2) {
      Err 'That''s a "Web application" client. Create a Desktop app client instead (section 1, step 5).'
    } else {
      Err "`"$src`" isn't a Google OAuth client file."
    }
    Say '  Press ENTER or SPACE to try again, any other key to skip this for now.'
    if (-not (Read-GoKey)) { return $false }
  }

  [void](New-Item -ItemType Directory -Force -Path $GoogleMcpDir)
  if (Test-Path $CredentialsPath) {
    $backup = "$CredentialsPath.backup-$(Get-Timestamp)"
    Copy-Item $CredentialsPath $backup
    Ok "Backed up the old client to $backup."
  }
  Move-Item -Force $src $CredentialsPath
  Ok "Moved it to $CredentialsPath."
  return $true
}

# --- gcloud CLI ---------------------------------------------------------------

function Test-GcloudWorks {
  if (-not $script:Gcloud) { return $false }
  & $script:Gcloud --version *> $null
  return ($LASTEXITCODE -eq 0)
}

# gcloud.cmd, never gcloud.ps1: the .ps1 is blocked where script execution is off.
function Find-Gcloud {
  $candidates = @(
    (Get-Command gcloud.cmd -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    (Join-Path $GcloudSdkDir 'bin\gcloud.cmd'),
    (Join-Path $env:LOCALAPPDATA 'Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'),
    (Join-Path $env:ProgramFiles 'Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd')
  )
  foreach ($candidate in $candidates) {
    if (-not $candidate -or -not (Test-Path $candidate)) { continue }
    $script:Gcloud = $candidate
    if (Test-GcloudWorks) { return $true }
  }
  $script:Gcloud = $null
  return $false
}

# Google's zip with Python bundled, unpacked to ~\google-cloud-sdk. No
# installer, no admin rights, and no changes to PATH.
function Install-GcloudZip {
  if (Test-Path $GcloudSdkDir) {
    Err "$GcloudSdkDir exists but its gcloud doesn't run, so I'm leaving it alone."
    return $false
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gcloud-" + [guid]::NewGuid())
  [void](New-Item -ItemType Directory -Path $tmp)
  $zip = Join-Path $tmp 'gcloud.zip'
  Say "Downloading the gcloud CLI (about 100 MB) into $GcloudSdkDir..."
  $oldProgress = $ProgressPreference
  try {
    # The progress bar slows Invoke-WebRequest down enormously in Windows PowerShell.
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $GcloudZipUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
    Say 'Unpacking...'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    Move-Item (Join-Path $tmp 'google-cloud-sdk') $GcloudSdkDir -ErrorAction Stop
    $script:Gcloud = Join-Path $GcloudSdkDir 'bin\gcloud.cmd'
    return $true
  } catch {
    Err "The download didn't work: $($_.Exception.Message)"
    return $false
  } finally {
    $ProgressPreference = $oldProgress
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

# Uses gcloud if it's already here, otherwise downloads it.
function Initialize-Gcloud {
  if (Find-Gcloud) { Ok "Using the gcloud CLI at $($script:Gcloud)."; return $true }
  Say 'I''ll download Google''s gcloud CLI and use it to create the project and turn on the APIs for you.'
  Say "It goes in $GcloudSdkDir and doesn't change PATH or install anything system-wide."
  if (-not (Confirm-Key 'Download it now?')) { return $false }
  if (-not (Install-GcloudZip)) { return $false }
  if (Find-Gcloud) { Ok "gcloud is installed: $($script:Gcloud)"; return $true }
  Err 'gcloud is installed but doesn''t start.'
  return $false
}

function Invoke-Gcloud { & $script:Gcloud --quiet @args }

# The first item of a JSON array gcloud printed, or $null. (Piping the parsed
# array enumerates it; Windows PowerShell's ConvertFrom-Json alone doesn't.)
function Get-FirstJsonItem($Json) {
  if (-not $Json) { return $null }
  $parsed = ($Json | Out-String) | ConvertFrom-Json
  return ($parsed | Select-Object -First 1)
}

function Get-GcloudAccount {
  $json = Invoke-Gcloud auth list --filter=status:ACTIVE --format=json 2>$null
  if ($LASTEXITCODE -ne 0) { return '' }
  $first = Get-FirstJsonItem $json
  if ($first) { return [string]$first.account }
  return ''
}

function Connect-Gcloud {
  $account = Get-GcloudAccount
  if ($account -and (Confirm-Key "gcloud is signed in as $account. Use this Google account to own the project?")) {
    $script:GcloudAccount = $account
    return $true
  }
  Say 'Your browser will open. Sign in with the Google account that should own the project'
  Say '(any of yours; it doesn''t have to be one you''ll connect), then click Allow.'
  Wait-Key 'Press any key to open the browser.'
  & $script:Gcloud auth login --brief | Out-Host
  if ($LASTEXITCODE -ne 0) { Err 'gcloud sign-in didn''t finish.'; return $false }
  $script:GcloudAccount = Get-GcloudAccount
  if ($script:GcloudAccount) { Ok "gcloud is signed in as $($script:GcloudAccount)." }
  return $true
}

# Reuses the project an earlier run created, or creates one.
function New-GcloudProject {
  $json = Invoke-Gcloud projects list "--filter=labels.$ProjectLabelKey=$ProjectLabelValue" --format=json 2>$null
  if ($LASTEXITCODE -eq 0) {
    $found = Get-FirstJsonItem $json
    if ($found) {
      $script:ProjectId = [string]$found.projectId
      Ok "Reusing your project $($script:ProjectId) (created by an earlier run)."
      return $true
    }
  }
  $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
  $id = 'google-mcp-' + (-join (1..6 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] }))
  while ($true) {
    Invoke-Gcloud projects create $id --name=google-mcp "--labels=$ProjectLabelKey=$ProjectLabelValue" | Out-Host
    if ($LASTEXITCODE -eq 0) { break }
    Warn 'Google didn''t create the project. A new Google Cloud account first has to accept the Terms of Service.'
    Open-Url 'https://console.cloud.google.com/'
    Say 'Accept the terms on that page if it asks, then come back.'
    Say '  Press ENTER or SPACE to try again, any other key to do this step in the browser instead.'
    if (-not (Read-GoKey)) { return $false }
  }
  $script:ProjectId = $id
  Ok "Created project $id."
  return $true
}

# --- Section 1: Google Cloud --------------------------------------------------

function Step-GoogleProject {
  Step '1 of 6' 'Create a Google Cloud project'
  if ($script:HadCredentials) {
    $id = Get-CredentialsProjectId
    if ($id) {
      $script:ProjectId = $id
      Ok "You already have a project: $id (your OAuth client belongs to it). Nothing to create."
      [void](Find-Gcloud)
      Wait-Key
      return
    }
  }

  if ((Initialize-Gcloud) -and (Connect-Gcloud) -and (New-GcloudProject)) { Wait-Key; return }

  Warn 'Let''s do this step in the browser instead.'
  Say 'Opening the Google Cloud "New project" page:'
  Open-Url 'https://console.cloud.google.com/projectcreate'
  Say
  Say '  1. Project name: anything, e.g. google-mcp'
  Say '  2. Organization / Location: leave as is ("No organization" is fine).'
  Say '  3. Click Create and wait a few seconds for it to finish.'
  Dim '(If you made one on an earlier run, don''t make another: just select it in the project picker.)'
  Wait-Key 'When the project is created, press any key.'

  Say
  Say 'Paste the project ID (shown under the project name, e.g. google-mcp-471203),'
  Say 'so the next links open straight to this project. Just press Enter to skip.'
  $id = Read-Line
  if ($id -cmatch '^[a-z][a-z0-9-]{4,28}[a-z0-9]$') {
    $script:ProjectId = $id
    Ok "Using project $id."
  } elseif ($id) {
    Warn 'That doesn''t look like a project ID, so the links will open without one. Pick the project in the picker at the top of each page.'
  } else {
    Say 'OK. On each page, make sure your project is selected in the picker at the top.'
  }
  Wait-Key
}

function Step-GoogleApis {
  Step '2 of 6' 'Enable the Google APIs'
  # Enabling an API that's already on is a no-op, so this is safe to repeat.
  if ($script:ProjectId -and (Test-GcloudWorks) -and (Get-GcloudAccount)) {
    Say "Turning on the Gmail, Calendar, Drive, Docs, Sheets and Slides APIs in $($script:ProjectId)..."
    Invoke-Gcloud services enable @Apis --project $script:ProjectId | Out-Host
    if ($LASTEXITCODE -eq 0) { Ok 'All six APIs are enabled.'; Wait-Key; return }
    Warn 'gcloud couldn''t enable them (is it signed in as the project''s owner?). Let''s do it in the browser instead.'
  }

  Say 'Opening a page that enables all six APIs at once (Gmail, Calendar, Drive, Docs, Sheets, Slides):'
  Open-Url (Get-ConsoleUrl "flows/enableapi?apiid=$($Apis -join ',')")
  Say
  Say '  1. Check that your project is the one selected.'
  Say '  2. Click Next, then Enable.'
  Say
  Dim 'If that page doesn''t work, go to APIs & Services > Library and enable each one by name.'
  Wait-Key
}

function Step-GoogleConsent {
  Step '3 of 6' 'Set up the OAuth consent screen'
  if ($script:HadCredentials) {
    Ok 'Already done: you have an OAuth client, and Google only lets you make one after this step.'
    Wait-Key
    return
  }
  $email = if ($script:GcloudAccount) { $script:GcloudAccount } else { 'your email' }
  Say 'Google doesn''t let any tool do this part, so it''s a few clicks. Opening Google Auth Platform:'
  Open-Url (Get-ConsoleUrl 'auth/overview')
  Say
  Say '  1. Click Get started.'
  Say "  2. App information: App name Google MCP, User support email $email. Next."
  Say '  3. Audience: External. Next.'
  Say "  4. Contact information: $email. Next."
  Say '  5. Tick the agreement and click Create.'
  Say
  Dim 'You don''t need to add any scopes here; the sign-in step asks for them itself.'
  Wait-Key
}

function Step-GoogleTestUsers {
  Step '4 of 6' 'Add your Google accounts as test users'
  Say 'Opening the Audience page:'
  Open-Url (Get-ConsoleUrl 'auth/audience')
  Say
  Say '  1. Under Test users, click + Add users.'
  Say '  2. Enter every Google address you''re going to connect (work, personal, ...).'
  Say '     Addresses already on the list stay there; only add new ones.'
  Say '  3. Click Save.'
  Say
  Say 'Leave the app in Testing. Any address left off here gets "Error 403: access_denied" when it signs in.'
  Wait-Key
}

function Step-GoogleClient {
  Step '5 of 6' 'Create the OAuth client and download it'
  if ($script:HadCredentials) {
    Ok "Already done: your OAuth client is at $CredentialsPath."
    Wait-Key
    return
  }
  Say 'Google doesn''t let any tool do this part either. Opening the "Create client" page:'
  Open-Url (Get-ConsoleUrl 'auth/clients/create')
  Say
  Say '  1. Application type: Desktop app  (not "Web application").'
  Say '  2. Name: anything, e.g. google-mcp-auth.'
  Say '  3. Click Create.'
  Say '  4. In the dialog that pops up, click Download JSON. Save it to Downloads (the default).'
  Wait-Key 'When the file has downloaded, press any key.'
}

function Step-GoogleCredentials {
  Step '6 of 6' 'Put the client file where the servers look for it'
  [void](Install-Credentials)
  Wait-Key
}

function Invoke-SectionGoogle {
  if (-not (Confirm-Section '1' 'Google Cloud setup' 'Creates the Google Cloud project and OAuth client every account and server shares. You only ever do this once.')) { return }
  $script:HadCredentials = Test-Credentials
  Step-GoogleProject
  Step-GoogleApis
  Step-GoogleConsent
  Step-GoogleTestUsers
  Step-GoogleClient
  Step-GoogleCredentials
  Ok 'Google Cloud setup is done.'
}

# --- Section 2: Repos, accounts, Claude ---------------------------------------

# Running from inside a clone of this repo: put the servers next to it.
function Find-AccountsDir {
  if (-not $ScriptDir) { return }
  if ((Split-Path $ScriptDir -Leaf) -eq $AccountsRepo -and (Test-Path (Join-Path $ScriptDir 'auth.js')) -and (Test-Path (Join-Path $ScriptDir 'store.js'))) {
    $script:AccountsDir = $ScriptDir
    $script:BaseDir = Split-Path $ScriptDir -Parent
  }
}

function Sync-Repo([string]$Repo) {
  $dest = Join-Path $script:BaseDir $Repo
  if (Test-Path (Join-Path $dest '.git')) {
    Say "$Repo is already at $dest. Pulling the latest..."
    # --ff-only never merges or discards anything; with local changes it just stops.
    & git -C $dest pull --ff-only | Out-Host
    if ($LASTEXITCODE -ne 0) { Warn "Couldn't update $Repo (local changes?). Using it as it is." }
    return $true
  }
  if (Test-Path $dest) {
    Err "$dest already exists and isn't a git repo, so I'm leaving it alone."
    return $false
  }
  & git clone "git@github.com:$GhOwner/$Repo.git" $dest | Out-Host
  return ($LASTEXITCODE -eq 0)
}

# npm ci installs exactly what's in package-lock.json and never rewrites it,
# so re-running doesn't leave changes in the repo. npm.cmd, not npm.ps1, which
# is blocked where script execution is off.
function Install-Deps([string]$Dir) {
  $name = Split-Path $Dir -Leaf
  Say "Installing $name's dependencies..."
  Push-Location $Dir
  try {
    & npm.cmd ci --no-fund --no-audit | Out-Host
    if ($LASTEXITCODE -ne 0) { & npm.cmd install --no-fund --no-audit | Out-Host }
    if ($LASTEXITCODE -ne 0) { Err "npm install failed in $Dir"; return $false }
  } finally {
    Pop-Location
  }
  Ok "$name is installed."
  return $true
}

function Step-ReposAccounts {
  Step '1 of 5' 'Get google-mcp-accounts'
  # Windows won't let npm replace files a running server has open, so Claude
  # (which runs the servers) has to be closed first.
  if (Test-ClaudeRunning) {
    Say 'Claude Desktop is running. It has to be closed while the servers are installed, or Windows blocks the update.'
    if (Confirm-Key 'Close Claude Desktop now? (It reopens at the end.)') {
      [void](Stop-Claude)
      $script:ClosedClaude = $true
      Ok 'Closed Claude Desktop.'
    } else {
      Warn 'Leaving it open. If an install fails with EBUSY or EPERM, close Claude and run this again.'
    }
  }

  if ($script:AccountsDir) {
    Ok "You're running this from $($script:AccountsDir), so the servers go next to it in $($script:BaseDir)."
  } else {
    # Default to wherever an earlier run put the repos.
    $default = Invoke-ClaudeConfig 'existing-base'
    if (-not $default) { $default = Join-Path $HOME 'google-mcp' }
    Say 'Where should the repos go? Press Enter for the default.'
    $dir = Read-Line "Folder [$default]:"
    if (-not $dir) { $dir = $default }
    $dir = Clean-Path $dir
    try { [void](New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop) } catch { Stop-Setup "Couldn't create $dir" }
    $script:BaseDir = (Resolve-Path $dir).Path
    $script:AccountsDir = Join-Path $script:BaseDir $AccountsRepo
  }
  if (-not (Sync-Repo $AccountsRepo)) { Stop-Setup "Can't continue without $AccountsRepo." }
  if (-not (Install-Deps $script:AccountsDir)) { Stop-Setup "Can't continue until $AccountsRepo installs." }
  Wait-Key
}

function Step-ReposServers {
  Step '2 of 5' 'Pick the servers you want'
  $script:Selected = @()
  foreach ($repo in $Repos) {
    if (Confirm-Key "Use $($repo.Label) ($($repo.Name))?") { $script:Selected += $repo.Name }
  }
  if ($script:Selected.Count -eq 0) {
    Warn 'You didn''t pick any servers. You can still connect accounts; run this again later to add servers.'
    Wait-Key
    return
  }
  Say
  foreach ($name in @($script:Selected)) {
    if (-not ((Sync-Repo $name) -and (Install-Deps (Join-Path $script:BaseDir $name)))) {
      Err "Skipping $name."
      $script:Selected = @($script:Selected | Where-Object { $_ -ne $name })
    }
  }
  Wait-Key
}

function Confirm-Credentials {
  if (Test-Credentials) { return $true }
  Warn "There's no OAuth client at $CredentialsPath yet (that's section 1, step 5)."
  Say 'If you''ve already downloaded it, I''ll find it now.'
  return (Install-Credentials)
}

function Get-AccountCount {
  return [int](Invoke-Node @'
try {
  console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.env.GMCP_FILE, "utf8"))).length);
} catch {
  console.log(0);
}
'@ @{ GMCP_FILE = $AccountsPath })
}

# The address an alias or nickname is connected to, or nothing.
function Get-AccountEmail([string]$Name) {
  return [string](Invoke-Node @'
try {
  const accounts = JSON.parse(require("fs").readFileSync(process.env.GMCP_FILE, "utf8"));
  const name = process.env.GMCP_NAME;
  const alias = Object.hasOwn(accounts, name)
    ? name
    : Object.keys(accounts).find((a) => (accounts[a].nicknames || []).includes(name));
  if (alias) console.log(accounts[alias].email);
} catch {}
'@ @{ GMCP_FILE = $AccountsPath; GMCP_NAME = $Name })
}

function Add-Nicknames([string]$Alias) {
  while ($true) {
    Say
    Say "Add nicknames for ${Alias}? Type them separated by commas (e.g. w, job)."
    Say 'Press ENTER (or type no) to move on without adding any.'
    $text = Read-Line
    if (-not $text -or $text.ToLower() -eq 'no') { return }
    foreach ($part in $text.Split(',')) {
      $nick = $part.Trim()
      if (-not $nick) { continue }
      if ($nick -notmatch $NamePattern) {
        Err "`"$nick`" isn't allowed. Use only letters, digits, - and _."
      } elseif ((Get-AccountEmail $nick) -and (Get-AccountEmail $nick) -eq (Get-AccountEmail $Alias)) {
        Ok "`"$nick`" already points to $Alias."
      } else {
        [void](Invoke-Auth @('--nick', $Alias, $nick))
      }
    }
  }
}

# Runs the sign-in as a child process so Esc can cancel it without Ctrl+C,
# which would stop this whole script.
function Connect-One([string]$Alias, [string]$Before) {
  Say
  Say 'Your browser will open a Google sign-in page. There:'
  $who = if ($Before) { "$Alias ($Before)" } else { $Alias }
  Say "  1. Pick (or sign in to) the Google account you want to call $who."
  Say '  2. On "Google hasn''t verified this app", click Continue (sometimes under Advanced).'
  Say '  3. Leave every permission ticked and click Continue.'
  Say '  4. When the tab says "Account connected", come back here.'
  Dim '(Press Esc here to cancel this sign-in.)'
  Wait-Key 'Press any key to open the browser.'

  $proc = Start-Process -FilePath $script:Node -ArgumentList @('auth.js', $Alias) -WorkingDirectory $script:AccountsDir -NoNewWindow -PassThru
  $null = $proc.Handle # without this, ExitCode is never filled in
  $cancelled = $false
  while (-not $proc.HasExited) {
    if ([Console]::KeyAvailable -and ([Console]::ReadKey($true)).Key -eq 'Escape') {
      $proc.Kill()
      $cancelled = $true
      break
    }
    Start-Sleep -Milliseconds 200
  }
  $proc.WaitForExit()
  if ($cancelled -or $proc.ExitCode -ne 0) {
    if ($cancelled) { Warn 'Sign-in cancelled.' } else { Err 'That account didn''t connect.' }
    Say 'Common causes: the address isn''t a test user (section 1, step 4), or you unticked a permission.'
    return $false
  }
  $after = Get-AccountEmail $Alias
  if ($Before -and $after -ne $Before) {
    Warn "`"$Alias`" used to be $Before and is now $after."
    Say "If that's not what you wanted, run this step again with alias $Alias and sign in as $Before."
  }
  return $true
}

function Connect-Accounts {
  while ($true) {
    Say
    Say 'Type an alias for the Google account to connect (e.g. work, personal).'
    Say 'You''ll then sign in to the account that alias should mean.'
    Say 'Press ENTER (or type no) when you''ve connected them all; nothing changes.'
    $alias = Read-Line
    if (-not $alias -or $alias.ToLower() -eq 'no') {
      if ((Get-AccountCount) -eq 0) { Warn 'No accounts are connected yet. Connect at least one first.'; continue }
      return
    }
    if ($alias -notmatch $NamePattern) { Err 'Use only letters, digits, - and _ (e.g. work, personal-2).'; continue }
    $email = Get-AccountEmail $alias
    if ($email) {
      Say "`"$alias`" is already connected to $email."
      if (-not (Confirm-Key "Sign in to it again to refresh it? (Sign in as $email; a different account would take over this alias.)")) { continue }
    }
    if (Connect-One $alias $email) { Add-Nicknames $alias }
  }
}

function Step-ReposConnect {
  Step '3 of 5' 'Connect your Google accounts'
  if (-not (Confirm-Credentials)) {
    Warn 'Skipping this step. Run this again once you have the OAuth client file.'
    Wait-Key
    return
  }
  if ((Get-AccountCount) -ne 0) {
    Say 'Already connected (these stay as they are unless you re-connect one):'
    [void](Invoke-Auth @('--list'))
  }
  Connect-Accounts
  Wait-Key
}

function Edit-Accounts {
  Say
  Say 'What do you want to change?'
  Say '  1) Connect another account (or re-connect one)'
  Say '  2) Add nicknames'
  Say '  3) Remove a nickname'
  Say '  4) Remove an account'
  Say '  5) Nothing, show the list again'
  switch (Read-Line) {
    '1' { Connect-Accounts }
    '2' { Add-Nicknames (Read-Line 'Which account (alias)?') }
    '3' { [void](Invoke-Auth @('--unnick', (Read-Line 'Which nickname?'))) }
    '4' {
      $alias = Read-Line 'Which alias?'
      if (Confirm-Key "Remove `"$alias`" ($(Get-AccountEmail $alias))? You'd have to sign in again to get it back.") {
        [void](Invoke-Auth @('--remove', $alias))
      }
    }
  }
}

function Step-ReposReview {
  Step '4 of 5' 'Check your accounts'
  while ($true) {
    [void](Invoke-Auth @('--list'))
    Say 'Each account''s "granted" line should list gmail, calendar, calendarList, drive, docs, sheets and slides.'
    Say 'If one is missing some, re-connect it with the same alias and leave every box ticked.'
    Say
    Say 'Is this list correct? Press ENTER (or type yes) if it is, or type no to change something.'
    $answer = (Read-Line).ToLower()
    if ($answer -in '', 'yes', 'y') { break }
    if ($answer -in 'no', 'n') { Edit-Accounts } else { Say 'Press ENTER if it''s correct, or type no.' }
  }
  Ok 'Accounts confirmed.'
  Wait-Key
}

function Get-ClaudePrompt {
  $json = (Invoke-ClaudeConfig 'print') -join "`n"
  return @"
Add these MCP servers to my Claude Desktop config at
$($script:ClaudeConfig)

- Back up the file first.
- Merge these entries into the existing "mcpServers" object. Keep every server
  that's already there; if one of these names already exists, replace its
  "command" and "args" and merge its "env", keeping any other settings on it.
- If the file doesn't exist, create it with just this content.
- Make sure the result is valid JSON.
- Create the folder $($script:FilesDir) if it doesn't exist.

When you're done, tell me to fully quit Claude Desktop (right-click its icon in
the system tray and choose Quit) and reopen it.

$json
"@
}

function Step-ReposClaude {
  Step '5 of 5' 'Connect the servers to Claude'
  if ($script:Selected.Count -eq 0) {
    Warn 'No servers were picked in step 2, so there''s nothing to add to Claude.'
    return
  }

  $default = Invoke-ClaudeConfig 'existing-files'
  if (-not $default) { $default = Join-Path (Get-DownloadsDir) 'google-mcp-files' }
  Say 'The Gmail, Drive and Docs/Sheets/Slides servers share one folder for files they download or attach.'
  $dir = Read-Line "Files folder [$default]:"
  if (-not $dir) { $dir = $default }
  $script:FilesDir = Clean-Path $dir
  [void](New-Item -ItemType Directory -Force -Path $script:FilesDir)

  while ($true) {
    Say
    Say 'How do you want to connect them?'
    Say '  1) Do it for me: add them to Claude Desktop''s config and restart Claude (recommended)'
    Say '  2) Give me a prompt to paste into Claude instead'
    $choice = Read-Line
    if ($choice -in '1', '2') { break }
    Say 'Type 1 or 2.'
  }

  if ($choice -eq '1') {
    Invoke-ClaudeConfig 'write' | Out-Host
    $status = $LASTEXITCODE
    if ($status -eq 0 -or ($status -eq 3 -and -not (Test-ClaudeRunning))) {
      Say
      if (Confirm-Key 'Claude needs a full restart to load the servers. Quit and reopen Claude Desktop now?') {
        Restart-Claude
      } else {
        Say 'Quit Claude from its system tray icon (right-click > Quit, not just closing the window) and reopen it when you''re ready.'
      }
      $script:ClosedClaude = $false # answered here, so don't reopen it again at the end
    } elseif ($status -ne 3) {
      return
    }
  } else {
    $prompt = Get-ClaudePrompt
    Say
    Write-Host 'Paste this into Claude Code (or any Claude that can edit files on this PC):' -ForegroundColor White
    Say ('-' * 64)
    Say $prompt
    Say ('-' * 64)
    try { Set-Clipboard -Value $prompt; Ok 'It''s also on your clipboard.' } catch {}
  }

  Say
  Say 'To check it worked: open a new chat in Claude Desktop, look for the servers under the tools icon,'
  Say 'and ask: "list my connected Google accounts".'
}

function Invoke-SectionRepos {
  if (-not (Confirm-Section '2' 'Repos, accounts and Claude' 'Clones the repos, connects each of your Google accounts, and adds the servers to Claude Desktop.')) { return }
  Step-ReposAccounts
  Step-ReposServers
  Step-ReposConnect
  Step-ReposReview
  Step-ReposClaude
}

# --- Main ---------------------------------------------------------------------

function Invoke-Setup {
  Banner 'Google MCP servers for Claude: guided setup'
  Say 'This walks you through everything, one step at a time. For each step it does the work'
  Say 'itself or opens the right page, then waits for you before moving on.'
  Say 'It''s safe to run again: what''s already set up is reused, never replaced without asking.'

  Find-AccountsDir
  Test-Assumptions
  Invoke-SectionGoogle
  Invoke-SectionRepos

  # Claude was closed for the install in section 2 but nothing reopened it.
  if ($script:ClosedClaude -and -not (Test-ClaudeRunning)) { Restart-Claude }

  Banner 'All done'
  Say 'Heads up: while your Google app is in Testing mode, Google expires sign-ins after 7 days.'
  Say 'When a server reports invalid_grant, re-connect that account:'
  $dir = if ($script:AccountsDir) { $script:AccountsDir } else { "path\to\$AccountsRepo" }
  Say "  cd `"$dir`"; node auth.js <alias>"
  Say
}

if (-not $env:SETUP_PS1_NO_MAIN) {
  try {
    Invoke-Setup
  } catch [System.OperationCanceledException] {
    Say
    Err $_.Exception.Message
  }
}
