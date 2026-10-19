
# ============================================================
# RAG Engineering Lab - GitHub Auto-Push with Popup Notification
#
# Features:
# 1. Monitors root folder and all subfolders.
# 2. Detects new, modified, renamed and deleted files.
# 3. Checks every 2 minutes.
# 4. Automatically commits and pushes changes to GitHub.
# 5. Displays a Windows popup after a successful push.
# 6. Displays an error popup if an operation fails.
# ============================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

$repositoryPath = $PSScriptRoot
$expectedRepository = "rahulranjan94/rag-engineering-lab"
$branch = "master"
$checkIntervalSeconds = 120

$device = "Laptop1: Rahul@Bengaluru_system"

# ------------------------------------------------------------
# POPUP NOTIFICATION FUNCTION
# ------------------------------------------------------------

function Show-Popup {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Icon = "Information"
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms

        $iconType = [System.Windows.Forms.MessageBoxIcon]::$Icon

        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            $iconType
        ) | Out-Null
    }
    catch {
        Write-Host $Message -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
# VALIDATE REPOSITORY
# ------------------------------------------------------------

Set-Location -LiteralPath $repositoryPath

if (-not (Test-Path (Join-Path $repositoryPath ".git"))) {
    Show-Popup -Title "GitHub Auto-Push Error" `
        -Message "The script is not inside a Git repository:`n$repositoryPath" `
        -Icon "Error"
    exit 1
}

# Validate Git installation
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Show-Popup -Title "GitHub Auto-Push Error" `
        -Message "Git is not installed or is not available in PATH." `
        -Icon "Error"
    exit 1
}

# ------------------------------------------------------------
# VALIDATE REMOTE REPOSITORY AND BRANCH
# ------------------------------------------------------------

$remoteUrl = (git remote get-url origin 2>$null | Select-Object -First 1)

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
    Show-Popup -Title "GitHub Auto-Push Error" `
        -Message "No Git remote named 'origin' was found." `
        -Icon "Error"
    exit 1
}

if ($remoteUrl -notmatch "rahulranjan94/rag-engineering-lab(?:\.git)?/?$") {
    Show-Popup -Title "GitHub Auto-Push Error" `
        -Message "The configured origin does not match the expected repository.`n`nConfigured:`n$remoteUrl`n`nExpected:`n$expectedRepository" `
        -Icon "Error"
    exit 1
}

# Confirm that the current branch is the expected branch.
$currentBranch = (git branch --show-current).Trim()

if ($currentBranch -ne $branch) {
    Show-Popup -Title "GitHub Auto-Push Error" `
        -Message "Current branch: $currentBranch`nExpected branch: $branch`n`nSwitch to the expected branch before starting." `
        -Icon "Error"
    exit 1
}

# ------------------------------------------------------------
# MAIN MONITORING LOOP
# ------------------------------------------------------------

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " RAG Engineering Lab - GitHub Auto-Push" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Repository: $expectedRepository"
Write-Host "Branch: $branch"
Write-Host "Monitoring: $repositoryPath"
Write-Host "Check interval: $checkIntervalSeconds seconds"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

while ($true) {

    try {
        Set-Location -LiteralPath $repositoryPath

        # Include staged, unstaged and untracked files.
        # --untracked-files=all detects files in subfolders.
        # --ignore-submodules avoids unrelated submodule changes.
        $status = @(git status --porcelain=v1 --untracked-files=all --ignore-submodules)

        if ($LASTEXITCODE -ne 0) {
            throw "Git could not read the repository status."
        }

        if ($status.Count -gt 0) {

            Write-Host "Changes detected. Preparing to push..." `
                -ForegroundColor Yellow

            # Stage additions, modifications, renames and deletions.
            git add -A -- .

            if ($LASTEXITCODE -ne 0) {
                throw "Git staging failed."
            }

            # Check for staged changes.
            git diff --cached --quiet

            if ($LASTEXITCODE -eq 1) {

                # Capture a concise list of changes for the commit.
                $changeSummary = @(git diff --cached --name-status)

                # Commit all staged changes.
                $commitMessage = "Auto-sync: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

                git -c core.quotepath=false commit -m $commitMessage

                if ($LASTEXITCODE -ne 0) {
                    throw "Git commit failed. Check Git identity and repository status."
                }

                # Push to GitHub.
                git push origin $branch

                if ($LASTEXITCODE -ne 0) {
                    throw "Git push failed. Check internet access, GitHub authentication, and remote changes."
                }

                $successTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                $message = @"
Your project changes have been pushed successfully!

From Device:
$device

GitHub Repository:
$expectedRepository

Branch:
$branch

Changes:
New, modified, renamed, or deleted files

Changed File Details:
$($changeSummary -join "`r`n")

Operation: PUSH (Local Repository -> GitHub)

Detailed Operation:
PUSH (Local Repository => $device to GitHub Repository => $expectedRepository)

Time:
$successTime

Your RAG Engineering Lab project is synchronized.
"@

                Write-Host $message -ForegroundColor Green

                Show-Popup `
                    -Title "RAG Engineering Lab - GitHub Auto-Push" `
                    -Message $message `
                    -Icon "Information"
            }
            elseif ($LASTEXITCODE -eq 0) {
                # No staged changes remain; this may happen if only
                # ignored files or previously staged changes were involved.
                Write-Host "No staged changes to commit." `
                    -ForegroundColor DarkGray
            }
            else {
                throw "Unable to check staged changes."
            }
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No changes detected." `
                -ForegroundColor DarkGray
        }
    }
    catch {
        $errorTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        $errorMessage = @"
GitHub Auto-Push could not complete successfully.

Repository:
$expectedRepository

Branch:
$branch

Time:
$errorTime

Error:
$($_.Exception.Message)

Please check VS Code terminal for details.
"@

        Write-Host $errorMessage -ForegroundColor Red

        Show-Popup `
            -Title "RAG Engineering Lab - Push Failed" `
            -Message $errorMessage `
            -Icon "Error"
    }

    # Wait two minutes before the next check.
    Start-Sleep -Seconds $checkIntervalSeconds
}
