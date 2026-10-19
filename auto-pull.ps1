# ============================================================
# RAG Engineering Lab - GitHub Auto-Pull with Popup Notification
#
# Features:
# 1. Checks GitHub every 2 minutes for new commits on the branch.
# 2. Pulls new, modified, renamed and deleted files into the local folder.
# 3. Local uncommitted edits do NOT block a pull: tracked edits are
#    stashed safely and restored after the pull (--autostash).
# 4. Shows a Windows popup after a successful pull (auto-closes).
# 5. Shows an error popup once per distinct error (no spam).
# ============================================================

$ErrorActionPreference = "Stop"

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
$popupTimeoutSeconds  = 30            # popup closes itself so the loop never blocks

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

    $lines = @($raw | ForEach-Object { "$_".TrimEnd() } | Where-Object { $_ -ne "" })

    [pscustomobject]@{
        ExitCode = $code
        Output   = $lines
    }
}

# ------------------------------------------------------------
# HELPER: POPUP (auto-closes so the loop never blocks)
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
    Show-Popup -Title "GitHub Auto-Pull Error" -Message $Message -Icon "Error"
    exit 1
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
# VALIDATE REMOTE AND BRANCH
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

# ------------------------------------------------------------
# MAIN MONITORING LOOP
# ------------------------------------------------------------

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " RAG Engineering Lab - GitHub Auto-Pull"   -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Repository: $expectedRepository"
Write-Host "Branch: $branch"
Write-Host "Monitoring: $repositoryPath"
Write-Host "Check interval: $checkIntervalSeconds seconds"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

$lastErrorMessage = $null

while ($true) {

    try {
        Set-Location -LiteralPath $repositoryPath

        # --- 0. Skip if another Git operation is in progress -------------
        # (for example the auto-push script is committing or pushing)
        $busy = (Test-Path -LiteralPath (Join-Path $gitDir "index.lock")) -or
                (Test-Path -LiteralPath (Join-Path $gitDir "rebase-merge")) -or
                (Test-Path -LiteralPath (Join-Path $gitDir "rebase-apply"))

        if ($busy) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Another Git operation is in progress. Will retry." -ForegroundColor DarkGray
        }
        else {
            # --- 1. Ask GitHub whether there is anything new ------------
            $fetch = Invoke-Git @("fetch", "origin", $branch)
            if ($fetch.ExitCode -ne 0) {
                $details = $fetch.Output -join "`n"
                throw "Git fetch failed. Check internet access and GitHub authentication.`n$details"
            }

            $count = Invoke-Git @("rev-list", "--count", "HEAD..origin/${branch}")
            if ($count.ExitCode -ne 0) {
                $details = $count.Output -join "`n"
                throw "Could not compare local branch with origin/$branch.`n$details"
            }
            $behind = [int]($count.Output | Select-Object -First 1)

            if ($behind -eq 0) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Already up to date with GitHub." -ForegroundColor DarkGray
            }
            else {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $behind new commit(s) on GitHub. Pulling..." -ForegroundColor Yellow

                # Were there uncommitted edits to tracked files before the pull?
                $dirty = Invoke-Git @("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules")
                $hadLocalEdits = ($dirty.Output.Count -gt 0)

                $oldHead = ($(Invoke-Git @("rev-parse", "HEAD")).Output | Select-Object -First 1)

                # --- 2. Pull (local edits are stashed and restored) -----
                $pull = Invoke-Git @("pull", "--rebase", "--autostash", "origin", $branch)

                # Files left in a conflicted state (e.g. restoring local edits clashed)
                $unmergedResult = Invoke-Git @("-c", "core.quotepath=false", "diff", "--name-only", "--diff-filter=U")
                $unmerged = @($unmergedResult.Output)

                if ($pull.ExitCode -ne 0 -and $unmerged.Count -eq 0) {
                    $details = $pull.Output -join "`n"
                    $null = Invoke-Git @("rebase", "--abort")
                    throw "Git pull failed. If this is a conflict, resolve it manually.`n$details"
                }

                $newHead = ($(Invoke-Git @("rev-parse", "HEAD")).Output | Select-Object -First 1)

                # --- 3. Build the notification ---------------------------
                $files = Invoke-Git @("-c", "core.quotepath=false", "diff", "--name-status", "$oldHead", "$newHead")
                $pending = @($files.Output)

                $logs = Invoke-Git @("log", "--pretty=format:%h %an: %s", "$oldHead..$newHead")
                $commits = @($logs.Output)

                $shown = @($pending | Select-Object -First $maxFilesInPopup)
                $extra = $pending.Count - $shown.Count
                $fileDetails = $shown -join "`n"
                if ($extra -gt 0) { $fileDetails += "`n... and $extra more" }
                if ([string]::IsNullOrWhiteSpace($fileDetails)) { $fileDetails = "(no file details available)" }

                $shownCommits = @($commits | Select-Object -First $maxCommitsInPopup)
                $extraCommits = $commits.Count - $shownCommits.Count
                $commitDetails = $shownCommits -join "`n"
                if ($extraCommits -gt 0) { $commitDetails += "`n... and $extraCommits more" }
                if ([string]::IsNullOrWhiteSpace($commitDetails)) { $commitDetails = "(none)" }

                $successTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                $noteLines = @()
                $popupIcon = "Information"

                if ($unmerged.Count -gt 0) {
                    $popupIcon = "Warning"
                    $noteLines += "WARNING: Your local uncommitted edits clash with GitHub changes in:"
                    $noteLines += ($unmerged | Select-Object -First 10)
                    $noteLines += "Your edits are saved in 'git stash'. Resolve the conflict in VS Code."
                    $noteLines += ""
                }
                elseif ($hadLocalEdits) {
                    $noteLines += "Note: your local uncommitted edits were kept and restored."
                    $noteLines += ""
                }

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
                    ""
                ) + $noteLines + @(
                    "Operation: PULL (GitHub -> Local Repository)",
                    "",
                    "Detailed Operation: PULL (GitHub Repository: $expectedRepository to $device)",
                    "",
                    "Time:",
                    $successTime,
                    "",
                    "Your RAG Engineering Lab project is synchronized."
                )
                $message = $message -join "`n"

                Write-Host $message -ForegroundColor Green

                Show-Popup `
                    -Title "RAG Engineering Lab - GitHub Auto-Pull" `
                    -Message $message `
                    -Icon $popupIcon
            }
        }

        # A clean cycle resets the error tracker.
        $lastErrorMessage = $null
    }
    catch {
        $errorTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $errorText = $_.Exception.Message

        $errorMessage = @(
            "GitHub Auto-Pull could not complete successfully.",
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
            $errorText,
            "",
            "Please check the VS Code terminal for details.",
            "The script will keep retrying every $checkIntervalSeconds seconds."
        ) -join "`n"

        Write-Host $errorMessage -ForegroundColor Red

        # Show the popup only when the error is new, not every 2 minutes.
        if ($errorText -ne $lastErrorMessage) {
            Show-Popup `
                -Title "RAG Engineering Lab - Pull Failed" `
                -Message $errorMessage `
                -Icon "Error"
            $lastErrorMessage = $errorText
        }
    }

    Start-Sleep -Seconds $checkIntervalSeconds
}