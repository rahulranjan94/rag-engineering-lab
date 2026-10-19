# ============================================================
# RAG Engineering Lab - GitHub Auto-Push with Popup Notification
#
# Features:
# 1. Monitors root folder and all subfolders.
# 2. Detects new, modified, renamed and deleted files.
# 3. Checks every 2 minutes.
# 4. Automatically commits and pushes changes to GitHub.
# 5. Retries a push that failed earlier (commit already exists locally).
# 6. Shows a Windows popup after a successful push (auto-closes).
# 7. Shows an error popup once per distinct error (no spam).
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
# HELPER: POPUP (non-blocking for long - auto-closes)
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
    Show-Popup -Title "GitHub Auto-Push Error" -Message $Message -Icon "Error"
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

# Name-status list of everything that is about to be pushed.
function Get-PendingChanges {
    if (Test-RemoteBranchKnown) {
        $r = Invoke-Git @("-c", "core.quotepath=false", "diff", "--name-status", "origin/${branch}...HEAD")
    }
    else {
        $r = Invoke-Git @("-c", "core.quotepath=false", "show", "--name-status", "--pretty=format:", "HEAD")
    }
    return @($r.Output)
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

if (-not (Test-Path -LiteralPath (Join-Path $repositoryPath ".git"))) {
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
# MAIN MONITORING LOOP
# ------------------------------------------------------------

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " RAG Engineering Lab - GitHub Auto-Push"   -ForegroundColor Cyan
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

        # --- 1. Detect and commit local changes -------------------------
        $status = Invoke-Git @("status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules")
        if ($status.ExitCode -ne 0) {
            $details = $status.Output -join "`n"
            throw "Git could not read the repository status.`n$details"
        }

        if ($status.Output.Count -gt 0) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Changes detected. Committing..." -ForegroundColor Yellow

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
            }
            elseif ($staged.ExitCode -ne 0) {
                throw "Unable to check staged changes."
            }
        }

        # --- 2. Push anything not yet on GitHub -------------------------
        # Checked every cycle, so a push that failed earlier is retried
        # even though the working tree is now clean.
        $ahead = Get-AheadCount

        if ($ahead -gt 0) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $ahead commit(s) to push..." -ForegroundColor Yellow

            $pending = Get-PendingChanges

            $push = Invoke-Git @("push", "origin", $branch)

            if ($push.ExitCode -ne 0) {
                $pushDetails = $push.Output -join "`n"

                # The remote may have new commits. Try one rebase, then push again.
                $pull = Invoke-Git @("pull", "--rebase", "--autostash", "origin", $branch)
                if ($pull.ExitCode -ne 0) {
                    $null = Invoke-Git @("rebase", "--abort")
                    throw "Git push failed. Check internet access, GitHub authentication and remote changes.`n$pushDetails"
                }

                $push = Invoke-Git @("push", "origin", $branch)
                if ($push.ExitCode -ne 0) {
                    $pushDetails = $push.Output -join "`n"
                    throw "Git push failed after rebasing onto the remote.`n$pushDetails"
                }
            }

            $successTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

            $shown = @($pending | Select-Object -First $maxFilesInPopup)
            $extra = $pending.Count - $shown.Count
            $fileDetails = $shown -join "`n"
            if ($extra -gt 0) { $fileDetails += "`n... and $extra more" }
            if ([string]::IsNullOrWhiteSpace($fileDetails)) { $fileDetails = "(no file details available)" }

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
                $successTime,
                "",
                "Your RAG Engineering Lab project is synchronized."
            ) -join "`n"

            Write-Host $message -ForegroundColor Green

            Show-Popup `
                -Title "RAG Engineering Lab - GitHub Auto-Push" `
                -Message $message `
                -Icon "Information"
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No changes detected." -ForegroundColor DarkGray
        }

        # A clean cycle resets the error tracker.
        $lastErrorMessage = $null
    }
    catch {
        $errorTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $errorText = $_.Exception.Message

        $errorMessage = @(
            "GitHub Auto-Push could not complete successfully.",
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
                -Title "RAG Engineering Lab - Push Failed" `
                -Message $errorMessage `
                -Icon "Error"
            $lastErrorMessage = $errorText
        }
    }

    Start-Sleep -Seconds $checkIntervalSeconds
}