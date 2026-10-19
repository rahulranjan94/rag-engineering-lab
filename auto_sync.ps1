# ============================================================
# RAG Engineering Lab - GitHub Auto-Sync (Push + Pull in one script)
#
# Every cycle (default 2 minutes) it runs these steps in order:
#   1. COMMIT  local new / modified / renamed / deleted files.
#   2. FETCH   from GitHub.
#   3. PULL    new GitHub commits into the laptop (rebase).
#   4. PUSH    local commits to GitHub.
#
# Because everything runs in a single loop, push and pull can never
# collide with each other. A popup is shown after a successful pull
# and after a successful push. Errors popup once per distinct error.
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
Write-Host "Mode: commit -> fetch -> pull -> push"
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

                $pendingFiles = Get-PendingPushChanges

                $push = Invoke-Git @("push", "origin", $branch)

                if ($push.ExitCode -ne 0) {
                    $pushDetails = $push.Output -join "`n"

                    # GitHub may have received a commit a moment ago. Rebase once, push again.
                    $retryPull = Invoke-Git @("pull", "--rebase", "origin", $branch)
                    if ($retryPull.ExitCode -ne 0) {
                        $null = Invoke-Git @("rebase", "--abort")
                        throw "Git push failed. Check internet access, GitHub authentication and remote changes.`n$pushDetails"
                    }

                    $push = Invoke-Git @("push", "origin", $branch)
                    if ($push.ExitCode -ne 0) {
                        $pushDetails = $push.Output -join "`n"
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
            $errorText,
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