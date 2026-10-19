# ============================================================
# RAG Engineering Lab - GitHub Auto-Push with Popup Notification
# Monitors the main repository and all subfolders.
# Detects new, modified, renamed, and deleted files.
# Checks every 2 minutes, commits and pushes to GitHub.
# Displays a popup after a successful push of a new commit.
# ============================================================

$ErrorActionPreference = "Stop"

# -------------------- Configuration ---------------------------

$repositoryPath = $PSScriptRoot
$branch = "master"
$remote = "origin"
$expectedRepository = "rahulranjan94/rag-engineering-lab"
$device = "Laptop1:Rahul@Bengaluru_system"
$intervalSeconds = 120

# -------------------- Windows notification support ------------

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
}
catch {
    Write-Host "ERROR: Windows Forms could not be loaded."
    Write-Host $_.Exception.Message
    exit 1
}

# -------------------- Git helper function ---------------------

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GitArgs
    )

    $output = & git -C $repositoryPath @GitArgs 2>&1
    $exitCode = $LASTEXITCODE

    [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = @($output | ForEach-Object { "$_" })
    }
}

# -------------------- Popup notification function --------------

function Show-SuccessNotification {
    param(
        [string]$Message
    )

    try {
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            "RAG Engineering Lab - GitHub Sync Successful",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1,
            [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly
        ) | Out-Null

        Write-Host "SUCCESS: Windows popup notification displayed."
    }
    catch {
        Write-Host "WARNING: GitHub push succeeded, but popup failed."
        Write-Host $_.Exception.Message
    }
}

# -------------------- Startup validation ----------------------

if (-not (Test-Path -LiteralPath $repositoryPath -PathType Container)) {
    Write-Host "ERROR: Repository folder does not exist:"
    Write-Host $repositoryPath
    exit 1
}

$gitVersion = Invoke-Git -GitArgs @("--version")

if ($gitVersion.ExitCode -ne 0) {
    Write-Host "ERROR: Git is unavailable. Check your installation."
    exit 1
}

$repoCheck = Invoke-Git -GitArgs @(
    "rev-parse", "--show-toplevel"
)

if ($repoCheck.ExitCode -ne 0) {
    Write-Host "ERROR: The script folder is not a Git repository."
    Write-Host "Place this script inside your repository root."
    exit 1
}

$actualRoot = ($repoCheck.Output -join "").Trim()

try {
    $repositoryPath = (Resolve-Path -LiteralPath $actualRoot).Path
}
catch {
    Write-Host "ERROR: Could not resolve repository root."
    exit 1
}

$branchResult = Invoke-Git -GitArgs @("branch", "--show-current")

if (
    $branchResult.ExitCode -ne 0 -or
    ($branchResult.Output -join "").Trim() -ne $branch
) {
    Write-Host "ERROR: Expected branch '$branch'."
    Write-Host "Current branch: $($branchResult.Output -join '')"
    exit 1
}

$remoteResult = Invoke-Git -GitArgs @(
    "remote", "get-url", $remote
)

if ($remoteResult.ExitCode -ne 0) {
    Write-Host "ERROR: Git remote '$remote' is not configured."
    exit 1
}

$remoteUrl = ($remoteResult.Output -join "").Trim()

if (
    $remoteUrl -notmatch
    '(^|[:/])rahulranjan94/rag-engineering-lab(\.git)?$'
) {
    Write-Host "ERROR: Unexpected GitHub repository URL:"
    Write-Host $remoteUrl
    exit 1
}

Write-Host ""
Write-Host "============================================================"
Write-Host " RAG Engineering Lab - GitHub Auto-Push Started"
Write-Host "============================================================"
Write-Host "Device     : $device"
Write-Host "Repository : $expectedRepository"
Write-Host "Local path : $repositoryPath"
Write-Host "Branch     : $branch"
Write-Host "Interval   : $intervalSeconds seconds"
Write-Host "Monitoring : Main folder and all Git-tracked subfolders"
Write-Host "Notification: After a successful push of a new commit"
Write-Host "Press Ctrl+C to stop."
Write-Host "============================================================"
Write-Host ""

# -------------------- Main monitoring loop --------------------

while ($true) {

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        Write-Host ""
        Write-Host "[$timestamp] Checking repository for changes..."

        # Check for an unfinished Git operation.
        $operationInProgress = $false

        foreach ($marker in @(
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "rebase-merge",
            "rebase-apply"
        )) {
            $markerResult = Invoke-Git -GitArgs @(
                "rev-parse", "--git-path", $marker
            )

            if ($markerResult.ExitCode -eq 0) {
                $markerPath = ($markerResult.Output -join "").Trim()

                if (-not [System.IO.Path]::IsPathRooted($markerPath)) {
                    $markerPath = Join-Path $repositoryPath $markerPath
                }

                if (Test-Path -LiteralPath $markerPath) {
                    Write-Host "Git operation in progress: $marker"
                    $operationInProgress = $true
                    break
                }
            }
        }

        if ($operationInProgress) {
            Write-Host "Skipping this cycle until the Git operation is resolved."
            continue
        }

        # Detect changes before staging anything.
        # Includes tracked changes and non-ignored untracked files.
        $status = Invoke-Git -GitArgs @(
            "status", "--porcelain", "--untracked-files=all"
        )

        if ($status.ExitCode -ne 0) {
            Write-Host "ERROR: Could not inspect repository status."
            $status.Output | ForEach-Object { Write-Host $_ }
            continue
        }

        if ($status.Output.Count -eq 0) {
            Write-Host "No local changes detected."
        }
        else {
            Write-Host "Local changes detected:"
            $status.Output | ForEach-Object { Write-Host $_ }

            # Stage new, modified, renamed, and deleted files.
            # Git ignores files and folders excluded by .gitignore.
            $stage = Invoke-Git -GitArgs @("add", "-A")

            if ($stage.ExitCode -ne 0) {
                Write-Host "STAGING FAILED:"
                $stage.Output | ForEach-Object { Write-Host $_ }
                continue
            }

            # Check whether staged changes require a commit.
            $diff = Invoke-Git -GitArgs @(
                "diff", "--cached", "--quiet"
            )

            if ($diff.ExitCode -eq 1) {

                $commitTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                $commit = Invoke-Git -GitArgs @(
                    "commit", "-m", "Auto-sync: $commitTime"
                )

                if ($commit.ExitCode -ne 0) {
                    Write-Host "COMMIT FAILED:"
                    $commit.Output | ForEach-Object { Write-Host $_ }
                    continue
                }

                Write-Host "New commit created successfully."

                # Push the new commit to GitHub.
                $push = Invoke-Git -GitArgs @(
                    "push", $remote, $branch
                )

                $push.Output | ForEach-Object { Write-Host $_ }

                if ($push.ExitCode -ne 0) {
                    Write-Host "PUSH FAILED."
                    Write-Host "The committed changes will be retried."
                    Write-Host "Check GitHub authentication and connectivity."
                    continue
                }

                Write-Host "GitHub push successful."

                # Display popup only after the push succeeds.
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

Operation:
Local Repository -> GitHub

Time:
$successTime

Your RAG Engineering Lab project is synchronized.
"@

                Show-SuccessNotification -Message $message

            }
            elseif ($diff.ExitCode -eq 0) {

                Write-Host "No staged changes require a new commit."

            }
            else {

                Write-Host "ERROR: Could not inspect staged changes."
                $diff.Output | ForEach-Object { Write-Host $_ }

            }
        }
    }
    catch {
        Write-Host "UNEXPECTED ERROR:"
        Write-Host $_.Exception.Message
        Write-Host "The script will retry during the next cycle."
    }
    finally {
        Start-Sleep -Seconds $intervalSeconds
    }
}