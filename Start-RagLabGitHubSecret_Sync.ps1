# ============================================================
# RAG Engineering Lab - GitHub Auto-Sync (Push + Pull in one script)
# File name : Start-RagLabGitHubSecret_Sync.ps1   (formerly auto_sync.ps1)
#
# Every cycle (default 2 minutes) it runs these steps in order:
#   1. COMMIT  local new / modified / renamed / deleted files
#              (secrets and sensitive files are automatically left out).
#   2. FETCH   from GitHub.
#   3. PULL    new GitHub commits into the laptop (rebase).
#   4. PUSH    local commits to GitHub (after a final secret scan).
#
# Because everything runs in a single loop, push and pull can never
# collide with each other. A popup is shown after a successful pull
# and after a successful push. Errors popup once per distinct error.
#
# SECRET PROTECTION (added after GitHub rejected a push with GH013):
#   - .env and the secrets\ folder are encrypted with git-crypt: GitHub only
#     ever stores scrambled data, and your real keys come back automatically
#     on any machine where you run "git-crypt unlock". (Set $useGitCrypt =
#     $false below to simply git-ignore .env instead.)
#   - *.pem, *.key etc. are added to .gitignore automatically.
#   - Before every commit, staged files are scanned for API keys / tokens /
#     private keys. Any file that matches is un-staged and NOT committed.
#     Encrypted files are only allowed through after the script has verified
#     that they really are stored encrypted.
#   - Before every push, the commits waiting to be pushed are scanned again.
#     If a secret is found, the script stops with clear recovery steps instead
#     of retrying a push that GitHub will always reject.
#
# Usage (VS Code terminal):   .\Start-RagLabGitHubSync.ps1
# ============================================================

$ErrorActionPreference = "Stop"

# Use UTF-8 so Git/GitHub messages are not garbled (e.g. the "Γöç" characters).
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
}
catch { }

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

$repositoryPath       = "D:\RAG_Learnings"
$expectedRepository   = "rahulranjan94/rag-engineering-lab"
$branch               = "master"      # change to "main" if your GitHub default branch is main
$checkIntervalSeconds = 120
$device               = "Laptop1: Rahul@Bengaluru_system"

$maxFilesInPopup      = 15            # keeps the popup a readable size
$maxCommitsInPopup    = 5
$maxErrorCharsInPopup = 1500
$popupTimeoutSeconds  = 30            # popup closes itself so the loop never blocks

# --- Secret protection ---------------------------------------

# $true  : .env and secrets\* are committed ENCRYPTED with git-crypt (recommended).
#          Requires the one-time setup in the guide (git-crypt init / unlock).
# $false : .env is only git-ignored and never uploaded at all.
$useGitCrypt = $true

# Lines added to .gitignore (if missing) so sensitive files are never tracked.
$ignoreRulesAlways   = @("*.pem", "*.key", "*.pfx", "*.p12")
$ignoreRulesPlainEnv = @(".env", ".env.*", "!.env.example", "!.env.sample", "!.env.template")

# Lines added to .gitattributes (if missing) when $useGitCrypt is $true.
# These files are stored encrypted in Git; later lines override earlier ones.
$gitAttributeRules = @(
    ".env filter=git-crypt diff=git-crypt",
    ".env.* filter=git-crypt diff=git-crypt",
    ".env.example !filter !diff",
    ".env.sample !filter !diff",
    ".env.template !filter !diff",
    "secrets/** filter=git-crypt diff=git-crypt"
)

# File names that are never committed, even if .gitignore is bypassed.
$blockedFilePatterns = @(
    ".env", ".env.*", "*.pem", "*.key", "*.pfx", "*.p12",
    "id_rsa", "id_ed25519", "credentials.json", "secrets.json"
)
$allowedFilePatterns = @(".env.example", ".env.sample", ".env.template")

# Text patterns that look like real credentials (case-sensitive match).
$secretPatterns = [ordered]@{
    "OpenAI / Anthropic API key" = '(?<![A-Za-z0-9])sk-(?=[A-Za-z0-9_\-]*\d)[A-Za-z0-9_\-]{20,}'
    "GitHub token"               = '(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})'
    "AWS access key ID"          = '(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])'
    "Google API key"             = '(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{35}'
    "Slack token"                = '(?<![A-Za-z0-9])xox[baprs]-[A-Za-z0-9\-]{10,}'
    "Private key block"          = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
}

# Tracks files already reported so the popup is shown once, not every cycle.
$script:reportedSkips = @{}

# ------------------------------------------------------------
# HELPER: RUN GIT SAFELY
# Captures stdout + stderr (git writes progress/warnings to stderr)
# without triggering terminating errors, and returns the exit code.
# Always call with an array: Invoke-Git @("status", "--porcelain")
# ------------------------------------------------------------

function Invoke-Git {
    param([string[]]$GitArgs)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw  = & git @GitArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    # stderr lines arrive as ErrorRecord objects; use their message text so we
    # never print "System.Management.Automation.RemoteException".
    $lines = @($raw | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message }
            else { "$_" }
        } |
        ForEach-Object { "$_".TrimEnd() } |
        Where-Object { $_ -ne "" -and $_ -ne "System.Management.Automation.RemoteException" })

    [pscustomobject]@{
        ExitCode = $code
        Output   = $lines
    }
}

# ------------------------------------------------------------
# HELPER: POPUP (auto-closes so the loop never blocks for long)
# ------------------------------------------------------------

function Show-Popup {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet("Information", "Warning", "Error")]
        [string]$Icon = "Information"
    )

    $iconCode = switch ($Icon) {
        "Error"   { 16 }
        "Warning" { 48 }
        default   { 64 }
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        # 4096 = always on top (system modal). Closes after the timeout.
        $null = $shell.Popup($Message, $popupTimeoutSeconds, $Title, ($iconCode + 4096))
    }
    catch {
        Write-Host $Message -ForegroundColor Yellow
    }
}

function Stop-WithError {
    param([string]$Message)

    Write-Host $Message -ForegroundColor Red
    Show-Popup -Title "GitHub Auto-Sync Error" -Message $Message -Icon "Error"
    exit 1
}

# Joins a list into text, showing at most $Max items.
function Format-Limited {
    param(
        [object[]]$Items,
        [int]$Max,
        [string]$EmptyText
    )

    $list = @($Items)
    if ($list.Count -eq 0) { return $EmptyText }

    $shown = @($list | Select-Object -First $Max)
    $text  = $shown -join "`n"
    $extra = $list.Count - $shown.Count
    if ($extra -gt 0) { $text += "`n... and $extra more" }
    return $text
}

# ------------------------------------------------------------
# HELPER: SECRET PROTECTION
# ------------------------------------------------------------

# True if the file name looks like a credentials file (.env, *.pem, ...).
function Test-BlockedFileName {
    param([string]$Path)

    $leaf = [System.IO.Path]::GetFileName($Path)
    foreach ($allowed in $allowedFilePatterns) {
        if ($leaf -like $allowed) { return $false }
    }
    foreach ($blocked in $blockedFilePatterns) {
        if ($leaf -like $blocked) { return $true }
    }
    return $false
}

# Returns the name of the first credential pattern found in the text, or $null.
function Find-SecretInText {
    param([string]$Text)

    foreach ($name in $secretPatterns.Keys) {
        if ($Text -cmatch $secretPatterns[$name]) { return $name }
    }
    return $null
}

# Makes sure .gitignore keeps sensitive files out of Git.
# With git-crypt, .env must NOT be ignored (it is stored encrypted instead),
# so any plain ".env" / ".env.*" rules are removed from .gitignore.
function Initialize-GitIgnore {
    $path     = Join-Path $repositoryPath ".gitignore"
    $existing = @()

    if (Test-Path -LiteralPath $path) {
        $existing = @(Get-Content -LiteralPath $path)
    }

    $wanted = @($ignoreRulesAlways)
    if (-not $useGitCrypt) { $wanted += $ignoreRulesPlainEnv }

    $lines = $existing
    if ($useGitCrypt) {
        $stale = @(".env", ".env.*", "/.env")
        $lines = @($existing | Where-Object { $stale -notcontains $_.Trim() })
    }
    $removed = $existing.Count - $lines.Count

    $missing = @($wanted | Where-Object { $lines -notcontains $_ })
    if ($missing.Count -eq 0 -and $removed -eq 0) { return }

    $newLines = @($lines)
    if ($missing.Count -gt 0) {
        $newLines += "# Added by Start-RagLabGitHubSync.ps1 - keeps secrets out of Git"
        $newLines += $missing
    }

    $text = ($newLines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))

    if ($removed -gt 0) {
        Write-Host "Removed $removed '.env' rule(s) from .gitignore (.env is now stored encrypted by git-crypt)." -ForegroundColor Cyan
    }
    if ($missing.Count -gt 0) {
        Write-Host "Added $($missing.Count) rule(s) to .gitignore to protect secrets." -ForegroundColor Cyan
    }
}

# Adds the git-crypt rules to .gitattributes (if missing).
function Initialize-GitAttributes {
    $path     = Join-Path $repositoryPath ".gitattributes"
    $raw      = ""
    $existing = @()

    if (Test-Path -LiteralPath $path) {
        $raw      = Get-Content -LiteralPath $path -Raw
        $existing = @(Get-Content -LiteralPath $path | ForEach-Object { $_.Trim() })
    }

    $missing = @($gitAttributeRules | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -eq 0) { return }

    $text = ""
    if ($raw -and -not $raw.EndsWith("`n")) { $text += "`r`n" }
    $text += "# Added by Start-RagLabGitHubSync.ps1 - these files are stored ENCRYPTED (git-crypt)`r`n"
    $text += ($missing -join "`r`n") + "`r`n"

    [System.IO.File]::AppendAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Updated .gitattributes with $($missing.Count) git-crypt rule(s)." -ForegroundColor Cyan
}

# Checks that git-crypt is installed, initialised/unlocked and not blocked by
# .gitignore. Stops the script (without touching Git) if anything is missing,
# because committing .env without encryption would expose your keys.
function Initialize-GitCrypt {
    if (-not $useGitCrypt) { return }

    if (-not (Get-Command git-crypt -ErrorAction SilentlyContinue)) {
        Stop-WithError ("git-crypt is not installed or is not available in PATH.`n`n" +
            "Install it (see the setup guide), open a NEW terminal and start this script again.`n`n" +
            "Or set `$useGitCrypt = `$false at the top of this script to just git-ignore .env.")
    }

    $keyFile = Join-Path $gitDir "git-crypt\keys\default"
    if (-not (Test-Path -LiteralPath $keyFile)) {
        Stop-WithError ("git-crypt is not set up for this repository (or this clone is still locked).`n`n" +
            "First machine (once):`n  git-crypt init`n`n" +
            "Another machine, right after cloning:`n  git-crypt unlock <path-to-your-key-file>`n`n" +
            "Then start this script again.")
    }

    Initialize-GitAttributes

    # .env must not be ignored, otherwise it would never be synced.
    $ignored = Invoke-Git @("check-ignore", "-v", "--", ".env")
    if ($ignored.ExitCode -eq 0) {
        $rule = $ignored.Output | Select-Object -First 1
        Stop-WithError ("'.env' is still being ignored by Git, so it would never sync:`n$rule`n`n" +
            "Remove that rule (the part after the file:line:), then start this script again.")
    }
}

# True if .gitattributes says this file is stored encrypted by git-crypt.
function Test-GitCryptProtected {
    param([string]$Path)

    if (-not $useGitCrypt) { return $false }

    $r = Invoke-Git @("check-attr", "filter", "--", $Path)
    return (($r.Output -join "") -match "filter:\s*git-crypt\s*$")
}

# Reads the first bytes of the STAGED copy of a file and confirms it carries the
# git-crypt header, i.e. it really is encrypted. This protects you if git-crypt
# was ever not working: plaintext is never committed by mistake.
function Test-StagedBlobEncrypted {
    param([string]$Path)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = "git"
    $psi.Arguments              = "cat-file blob `":$Path`""
    $psi.WorkingDirectory       = $repositoryPath
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow         = $true

    $buffer = New-Object byte[] 10
    $read   = 0
    $proc   = $null

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stream = $proc.StandardOutput.BaseStream
        while ($read -lt 10) {
            $n = $stream.Read($buffer, $read, 10 - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    }
    catch {
        return $false
    }
    finally {
        if ($proc) {
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
            $proc.Dispose()
        }
    }

    if ($read -eq 0) { return $true }   # empty file: nothing to protect
    if ($read -lt 9) { return $false }

    return ($buffer[0] -eq 0 -and [System.Text.Encoding]::ASCII.GetString($buffer, 1, 8) -eq "GITCRYPT")
}

# Un-stages any staged file that is a sensitive file or contains a credential,
# so it is never committed. The file itself is left untouched on disk.
function Protect-StagedChanges {
    $r = Invoke-Git @("-c", "core.quotepath=false", "diff", "--cached", "--name-only", "--diff-filter=ACMR")
    if ($r.ExitCode -ne 0) {
        $details = $r.Output -join "`n"
        throw "Could not list staged files for the secret scan.`n$details"
    }

    $newSkips = @()

    foreach ($file in $r.Output) {
        $reason = $null

        if (Test-GitCryptProtected $file) {
            # Vault file (.env, secrets\*): real keys are fine, but ONLY if the
            # staged copy is genuinely encrypted.
            if (-not (Test-StagedBlobEncrypted $file)) {
                $reason = "git-crypt did NOT encrypt it - check 'git-crypt status'"
            }
        }
        elseif (Test-BlockedFileName $file) {
            $reason = "sensitive file name"
        }
        else {
            # --no-textconv: never let git-crypt decrypt the text for the scan.
            $d = Invoke-Git @("diff", "--cached", "-U0", "--no-color", "--no-ext-diff", "--no-textconv", "--", $file)
            foreach ($line in $d.Output) {
                if ($line.StartsWith("+") -and -not $line.StartsWith("+++")) {
                    $hit = Find-SecretInText $line
                    if ($hit) { $reason = $hit; break }
                }
            }
        }

        if ($reason) {
            $null = Invoke-Git @("reset", "-q", "--", $file)

            $key = "$file|$reason"
            if (-not $script:reportedSkips.ContainsKey($key)) {
                $script:reportedSkips[$key] = $true
                $newSkips += "$file  ($reason)"
            }
        }
    }

    if ($newSkips.Count -gt 0) {
        $message = @(
            "Some files were NOT committed because they appear to contain secrets:",
            "",
            (Format-Limited -Items $newSkips -Max $maxFilesInPopup -EmptyText ""),
            "",
            "Move the key into .env or the secrets\ folder (stored encrypted),",
            "or replace it with a placeholder. The file will be synced automatically",
            "once it is clean.",
            "",
            "All other files are still being synced normally."
        ) -join "`n"

        Write-Host $message -ForegroundColor Yellow
        Show-Popup -Title "RAG Engineering Lab - Secret Protection" -Message $message -Icon "Warning"
    }
}

# Scans every commit that is waiting to be pushed. Returns a list of findings.
function Find-OutgoingSecrets {
    if (Test-RemoteBranchKnown) { $range = "origin/${branch}..HEAD" }
    else                        { $range = "HEAD" }

    $r = Invoke-Git @("-c", "core.quotepath=false", "log", "-p", "-U0", "--no-color", "--no-ext-diff", "--no-textconv",
                      "--pretty=format:@@COMMIT@@ %h", $range)
    if ($r.ExitCode -ne 0) {
        $details = $r.Output -join "`n"
        throw "Could not scan commits waiting to be pushed.`n$details"
    }

    $findings = New-Object System.Collections.Generic.List[string]
    $commit   = ""
    $file     = ""

    foreach ($line in $r.Output) {
        if ($line.StartsWith("@@COMMIT@@ ")) {
            $commit = $line.Substring(11)
            $file   = ""
            continue
        }

        if ($line.StartsWith("+++ ")) {
            $file = $line.Substring(4)
            if ($file -eq "/dev/null")      { $file = "" }
            elseif ($file.StartsWith("b/")) { $file = $file.Substring(2) }

            if ($file -and (Test-BlockedFileName $file)) {
                $findings.Add("commit $commit : $file (sensitive file name)")
            }
            continue
        }

        if ($file -and $line.StartsWith("+")) {
            $hit = Find-SecretInText $line
            if ($hit) { $findings.Add("commit $commit : $file ($hit)") }
        }
    }

    return @($findings | Select-Object -Unique)
}

# Stops the script (retrying can never succeed) and explains how to recover.
function Stop-WithSecretBlock {
    param([string[]]$Findings)

    $details = Format-Limited -Items $Findings -Max $maxFilesInPopup -EmptyText "(see GitHub's message in the terminal)"

    $message = @(
        "GitHub Auto-Sync has STOPPED to protect you.",
        "Secrets / credentials were found in commits waiting to be pushed:",
        "",
        $details,
        "",
        "Nothing sensitive has reached GitHub.",
        "",
        "How to fix (VS Code terminal, inside $repositoryPath):",
        "1. Revoke / rotate the exposed API key in the provider's dashboard.",
        "2. Remove the key from the affected files. Keep keys only in .env or",
        "   the secrets\ folder (stored encrypted) - or use a placeholder.",
        "3. Run:  git reset origin/$branch",
        "   (un-commits the local auto-sync commits, keeps all your files)",
        "4. Start this script again.",
        "",
        "Do not use GitHub's 'allow secret' link - that publishes the key."
    ) -join "`n"

    Write-Host $message -ForegroundColor Red
    Show-Popup -Title "RAG Engineering Lab - Secret Detected, Sync Stopped" -Message $message -Icon "Error"
    exit 1
}

# ------------------------------------------------------------
# HELPER: REMOTE TRACKING INFO
# ------------------------------------------------------------

function Test-RemoteBranchKnown {
    $r = Invoke-Git @("rev-parse", "--verify", "--quiet", "refs/remotes/origin/$branch")
    return ($r.ExitCode -eq 0)
}

# Number of local commits not yet on origin/<branch>.
function Get-AheadCount {
    if (-not (Test-RemoteBranchKnown)) { return 1 }

    $r = Invoke-Git @("rev-list", "--count", "origin/${branch}..HEAD")
    if ($r.ExitCode -ne 0) {
        $details = $r.Output -join "`n"
        throw "Could not compare local commits with origin/$branch.`n$details"
    }
    return [int]($r.Output | Select-Object -First 1)
}

# Number of GitHub commits not yet on the laptop.
function Get-BehindCount {
    $r = Invoke-Git @("rev-list", "--count", "HEAD..origin/${branch}")
    if ($r.ExitCode -ne 0) {
        $details = $r.Output -join "`n"
        throw "Could not compare local branch with origin/$branch.`n$details"
    }
    return [int]($r.Output | Select-Object -First 1)
}

# Name-status list of everything that is about to be pushed.
function Get-PendingPushChanges {
    if (Test-RemoteBranchKnown) {
        $r = Invoke-Git @("-c", "core.quotepath=false", "diff", "--name-status", "origin/${branch}...HEAD")
    }
    else {
        $r = Invoke-Git @("-c", "core.quotepath=false", "show", "--name-status", "--pretty=format:", "HEAD")
    }
    return @($r.Output)
}

# ------------------------------------------------------------
# HELPER: NOTIFICATIONS
# ------------------------------------------------------------

function Show-PullSuccess {
    param([string[]]$Commits, [string[]]$Files)

    $commitDetails = Format-Limited -Items $Commits -Max $maxCommitsInPopup -EmptyText "(none)"
    $fileDetails   = Format-Limited -Items $Files   -Max $maxFilesInPopup   -EmptyText "(no file details available)"
    $time          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $message = @(
        "New changes from GitHub have been pulled successfully!",
        "",
        "To Device:",
        $device,
        "",
        "GitHub Repository:",
        $expectedRepository,
        "",
        "Branch:",
        $branch,
        "",
        "Commits Received:",
        $commitDetails,
        "",
        "Changed File Details:",
        $fileDetails,
        "",
        "Operation: PULL (GitHub -> Local Repository)",
        "",
        "Detailed Operation: PULL (GitHub Repository: $expectedRepository to $device)",
        "",
        "Time:",
        $time,
        "",
        "Your RAG Engineering Lab project is synchronized."
    ) -join "`n"

    Write-Host $message -ForegroundColor Green

    Show-Popup `
        -Title "RAG Engineering Lab - GitHub Auto-Pull" `
        -Message $message `
        -Icon "Information"
}

function Show-PushSuccess {
    param([string[]]$Files)

    $fileDetails = Format-Limited -Items $Files -Max $maxFilesInPopup -EmptyText "(no file details available)"
    $time        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $message = @(
        "Your project changes have been pushed successfully!",
        "",
        "From Device:",
        $device,
        "",
        "GitHub Repository:",
        $expectedRepository,
        "",
        "Branch:",
        $branch,
        "",
        "Changed File Details:",
        $fileDetails,
        "",
        "Operation: PUSH (Local Repository -> GitHub)",
        "",
        "Detailed Operation: PUSH ($device to GitHub Repository: $expectedRepository)",
        "",
        "Time:",
        $time,
        "",
        "Your RAG Engineering Lab project is synchronized."
    ) -join "`n"

    Write-Host $message -ForegroundColor Green

    Show-Popup `
        -Title "RAG Engineering Lab - GitHub Auto-Push" `
        -Message $message `
        -Icon "Information"
}

# ------------------------------------------------------------
# VALIDATE ENVIRONMENT
# ------------------------------------------------------------

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-WithError "Git is not installed or is not available in PATH."
}

if (-not (Test-Path -LiteralPath $repositoryPath -PathType Container)) {
    Stop-WithError "The repository folder was not found:`n$repositoryPath"
}

Set-Location -LiteralPath $repositoryPath

$gitDir = Join-Path $repositoryPath ".git"

if (-not (Test-Path -LiteralPath $gitDir)) {
    Stop-WithError "The folder is not a Git repository:`n$repositoryPath"
}

# ------------------------------------------------------------
# VALIDATE REMOTE, BRANCH AND GIT IDENTITY
# ------------------------------------------------------------

$r = Invoke-Git @("remote", "get-url", "origin")
$remoteUrl = $r.Output | Select-Object -First 1

if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
    Stop-WithError "No Git remote named 'origin' was found."
}

$repoPattern = [regex]::Escape($expectedRepository) + "(\.git)?/?$"
if ($remoteUrl -notmatch $repoPattern) {
    Stop-WithError "The configured origin does not match the expected repository.`n`nConfigured:`n$remoteUrl`n`nExpected:`n$expectedRepository"
}

$r = Invoke-Git @("rev-parse", "--abbrev-ref", "HEAD")
$currentBranch = $r.Output | Select-Object -First 1

if ($r.ExitCode -ne 0 -or $currentBranch -ne $branch) {
    Stop-WithError "Current branch: $currentBranch`nExpected branch: $branch`n`nSwitch to the expected branch before starting."
}

$gitName  = Invoke-Git @("config", "user.name")
$gitEmail = Invoke-Git @("config", "user.email")
if ($gitName.ExitCode -ne 0 -or $gitEmail.ExitCode -ne 0) {
    Stop-WithError "Git user.name / user.email is not configured.`n`nRun:`ngit config --global user.name `"Your Name`"`ngit config --global user.email `"you@example.com`""
}

# Keep credential files out of Git (or encrypted) from now on.
Initialize-GitIgnore
Initialize-GitCrypt

# ------------------------------------------------------------
# MAIN SYNC LOOP
# ------------------------------------------------------------

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " RAG Engineering Lab - GitHub Auto-Sync"   -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Repository: $expectedRepository"
Write-Host "Branch: $branch"
Write-Host "Monitoring: $repositoryPath"
Write-Host "Check interval: $checkIntervalSeconds seconds"
Write-Host "Mode: commit -> fetch -> pull -> scan -> push (secret protection ON)"
if ($useGitCrypt) { Write-Host "Secrets: .env and secrets\ are stored ENCRYPTED (git-crypt)" }
else              { Write-Host "Secrets: .env is git-ignored (never uploaded)" }
Write-Host "Press Ctrl+C to stop."
Write-Host ""

$lastErrorMessage = $null

while ($true) {

    try {
        Set-Location -LiteralPath $repositoryPath

        # --- 0. Skip if a Git operation is already in progress -----------
        # (for example VS Code is committing, or a rebase is unfinished)
        $busy = (Test-Path -LiteralPath (Join-Path $gitDir "index.lock")) -or
                (Test-Path -LiteralPath (Join-Path $gitDir "rebase-merge")) -or
                (Test-Path -LiteralPath (Join-Path $gitDir "rebase-apply")) -or
                (Test-Path -LiteralPath (Join-Path $gitDir "MERGE_HEAD"))

        if ($busy) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Another Git operation is in progress. Will retry." -ForegroundColor DarkGray
        }
        else {
            $didSomething = $false

            # --- 1. COMMIT local changes ---------------------------------
            $status = Invoke-Git @("status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules")
            if ($status.ExitCode -ne 0) {
                $details = $status.Output -join "`n"
                throw "Git could not read the repository status.`n$details"
            }

            if ($status.Output.Count -gt 0) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Local changes detected. Committing..." -ForegroundColor Yellow

                $add = Invoke-Git @("add", "-A", "--", ".")
                if ($add.ExitCode -ne 0) {
                    $details = $add.Output -join "`n"
                    throw "Git staging failed.`n$details"
                }

                # Un-stage anything that looks like a secret BEFORE committing.
                Protect-StagedChanges

                $staged = Invoke-Git @("diff", "--cached", "--quiet")

                if ($staged.ExitCode -eq 1) {
                    $commitMessage = "Auto-sync: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
                    $commit = Invoke-Git @("-c", "core.quotepath=false", "commit", "-m", $commitMessage)
                    if ($commit.ExitCode -ne 0) {
                        $details = $commit.Output -join "`n"
                        throw "Git commit failed. Check Git identity and repository status.`n$details"
                    }
                    $didSomething = $true
                }
                elseif ($staged.ExitCode -ne 0) {
                    throw "Unable to check staged changes."
                }
            }

            # --- 2. FETCH from GitHub ------------------------------------
            $fetch = Invoke-Git @("fetch", "origin", $branch)
            if ($fetch.ExitCode -ne 0) {
                $details = $fetch.Output -join "`n"
                throw "Git fetch failed. Check internet access and GitHub authentication.`n$details"
            }

            # --- 3. PULL new GitHub commits ------------------------------
            $behind = Get-BehindCount

            if ($behind -gt 0) {
                $didSomething = $true
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $behind new commit(s) on GitHub. Pulling..." -ForegroundColor Yellow

                # Work out exactly what GitHub added (independent of local commits).
                $mb = Invoke-Git @("merge-base", "HEAD", "origin/${branch}")
                if ($mb.ExitCode -ne 0) {
                    $details = $mb.Output -join "`n"
                    throw "Could not find a common history with origin/$branch.`n$details"
                }
                $base = $mb.Output | Select-Object -First 1

                $logs  = Invoke-Git @("log", "--pretty=format:%h %an: %s", "$base..origin/${branch}")
                $files = Invoke-Git @("-c", "core.quotepath=false", "diff", "--name-status", "$base", "origin/${branch}")
                $receivedCommits = @($logs.Output)
                $receivedFiles   = @($files.Output)

                $pull = Invoke-Git @("pull", "--rebase", "origin", $branch)
                if ($pull.ExitCode -ne 0) {
                    $details = $pull.Output -join "`n"
                    $null = Invoke-Git @("rebase", "--abort")
                    throw "Git pull failed. If this is a conflict, run 'git pull --rebase' in the VS Code terminal and resolve it manually.`n$details"
                }

                Show-PullSuccess -Commits $receivedCommits -Files $receivedFiles
            }

            # --- 4. PUSH local commits -----------------------------------
            # Checked every cycle, so a push that failed earlier is retried
            # even though the working tree is now clean.
            $ahead = Get-AheadCount

            if ($ahead -gt 0) {
                $didSomething = $true
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $ahead commit(s) to push..." -ForegroundColor Yellow

                # Final safety net: never push commits that contain secrets.
                $leaks = Find-OutgoingSecrets
                if ($leaks.Count -gt 0) {
                    Stop-WithSecretBlock -Findings $leaks
                }

                $pendingFiles = Get-PendingPushChanges

                $push = Invoke-Git @("push", "origin", $branch)

                if ($push.ExitCode -ne 0) {
                    $pushDetails = $push.Output -join "`n"

                    # GitHub secret scanning / push protection: retrying can never work.
                    if ($pushDetails -match "GH013|push protection|Push cannot contain secrets") {
                        $reported = @($push.Output | Where-Object { $_ -match "commit:|path:|Key|key" } | Select-Object -First 10)
                        Stop-WithSecretBlock -Findings $reported
                    }

                    # GitHub may have received a commit a moment ago. Rebase once, push again.
                    $retryPull = Invoke-Git @("pull", "--rebase", "origin", $branch)
                    if ($retryPull.ExitCode -ne 0) {
                        $null = Invoke-Git @("rebase", "--abort")
                        throw "Git push failed. Check internet access, GitHub authentication and remote changes.`n$pushDetails"
                    }

                    $push = Invoke-Git @("push", "origin", $branch)
                    if ($push.ExitCode -ne 0) {
                        $pushDetails = $push.Output -join "`n"
                        if ($pushDetails -match "GH013|push protection|Push cannot contain secrets") {
                            $reported = @($push.Output | Where-Object { $_ -match "commit:|path:|Key|key" } | Select-Object -First 10)
                            Stop-WithSecretBlock -Findings $reported
                        }
                        throw "Git push failed after rebasing onto the remote.`n$pushDetails"
                    }
                }

                Show-PushSuccess -Files $pendingFiles
            }

            if (-not $didSomething) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No changes. Laptop and GitHub are in sync." -ForegroundColor DarkGray
            }
        }

        # A clean cycle resets the error tracker.
        $lastErrorMessage = $null
    }
    catch {
        $errorTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $errorText = $_.Exception.Message

        # Keep the popup readable; the full text is always in the terminal.
        $popupErrorText = $errorText
        if ($popupErrorText.Length -gt $maxErrorCharsInPopup) {
            $popupErrorText = $popupErrorText.Substring(0, $maxErrorCharsInPopup) + "`n... (see the VS Code terminal for the full message)"
        }

        $errorMessage = @(
            "GitHub Auto-Sync could not complete successfully.",
            "",
            "Repository:",
            $expectedRepository,
            "",
            "Branch:",
            $branch,
            "",
            "Time:",
            $errorTime,
            "",
            "Error:",
            $popupErrorText,
            "",
            "Please check the VS Code terminal for details.",
            "The script will keep retrying every $checkIntervalSeconds seconds."
        ) -join "`n"

        Write-Host $errorMessage -ForegroundColor Red

        # Show the popup only when the error is new, not every 2 minutes.
        if ($errorText -ne $lastErrorMessage) {
            Show-Popup `
                -Title "RAG Engineering Lab - Sync Failed" `
                -Message $errorMessage `
                -Icon "Error"
            $lastErrorMessage = $errorText
        }
    }

    Start-Sleep -Seconds $checkIntervalSeconds
}