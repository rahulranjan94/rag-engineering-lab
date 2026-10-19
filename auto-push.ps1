
# ============================================================
# RAG Engineering Lab - GitHub Auto-Push
# Checks for local changes every 2 minutes.
# Commits and pushes changes to GitHub.
# ============================================================

$ErrorActionPreference = "Stop"

$repositoryPath = $PSScriptRoot
$branch = "master"
$remote = "origin"
$expectedRepository = "rahulranjan94/rag-engineering-lab"
$device = "Laptop1:Rahul@Bengaluru_system"
$intervalSeconds = 120

# -------------------- Windows notifications ------------------

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
}
catch {
    Write-Host "ERROR: Could not load Windows notification support."
    exit 1
}

# -------------------- Git helper -----------------------------

function Invoke-Git {
    param([string[]]$GitArgs)

    $output = & git @GitArgs 2>&1
    $exitCode = $LASTEXITCODE

    [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = @($output | ForEach-Object { "$_" })
    }
}

# -------------------- Startup validation ---------------------

Set-Location -LiteralPath $repositoryPath

$gitVersion = Invoke-Git -GitArgs @("--version")

if ($gitVersion.ExitCode -ne 0) {
    Write-Host "ERROR: Git is unavailable. Check your Git installation."
    exit 1
}

$repoCheck = Invoke-Git -GitArgs @(
    "rev-parse", "--is-inside-work-tree"
)

if ($repoCheck.ExitCode -ne 0 -or
    ($repoCheck.Output -join "").Trim() -ne "true") {
    Write-Host "ERROR: This folder is not a Git repository."
    exit 1
}

$branchResult = Invoke-Git -GitArgs @(
    "branch", "--show-current"
)

if ($branchResult.ExitCode -ne 0 -or
    ($branchResult.Output -join "").Trim() -ne $branch) {
    Write-Host "ERROR: Expected branch '$branch'."
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

if ($remoteUrl -notmatch
    '(^|[:/])rahulranjan94/rag-engineering-lab(\.git)?$') {
    Write-Host "ERROR: Unexpected GitHub repository URL:"
    Write-Host $remoteUrl
    exit 1
}

Write-Host ""
Write-Host "GitHub auto-push started."
Write-Host "Device: $device"
Write-Host "Repository: $expectedRepository"
Write-Host "Branch: $branch"
Write-Host "Interval: $intervalSeconds seconds"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

# -------------------- Main loop ------------------------------

while ($true) {
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        Write-Host ""
        Write-Host "[$timestamp] Checking local changes..."

        # Do not operate during an unfinished merge or rebase.
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
            Write-Host "Skipping this cycle. Resolve the Git operation first."
            continue
        }

        # Stage new, modified, and deleted files.
        # Review .gitignore first to avoid staging secrets or local files.
        $stage = Invoke-Git -GitArgs @("add", "-A")

        if ($stage.ExitCode -ne 0) {
            Write-Host "STAGING FAILED:"
            $stage.Output | ForEach-Object { Write-Host $_ }
            continue
        }

        # Determine whether a new commit is required.
        $diff = Invoke-Git -GitArgs @(
            "diff", "--cached", "--quiet"
        )

        $commitCreated = $false

        if ($diff.ExitCode -eq 1) {
            $commit = Invoke-Git -GitArgs @(
                "commit", "-m", "Auto-sync: $timestamp"
            )

            if ($commit.ExitCode -ne 0) {
                Write-Host "COMMIT FAILED:"
                $commit.Output | ForEach-Object { Write-Host $_ }
                continue
            }

            $commitCreated = $true
            Write-Host "New commit created."
        }
        elseif ($diff.ExitCode -eq 0) {
            Write-Host "No new changes to commit."
        }
        else {
            Write-Host "Could not check staged changes. Skipping push."
            continue
        }

        # Push even when no new commit was created:
        # this retries commits left behind by a previous failed push.
        $push = Invoke-Git -GitArgs @(
            "push", $remote, $branch
        )

        $push.Output | ForEach-Object { Write-Host $_ }

        if ($push.ExitCode -ne 0) {
            Write-Host "PUSH FAILED. Will retry during the next cycle."
            continue
        }

        Write-Host "GitHub push successful."

        # Notify only when this cycle created and pushed a commit.
        if ($commitCreated) {
            $successTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

            $message = @"
Your code has been pushed successfully!

From Device:
Laptop1:Rahul@Bengaluru_system

To GitHub Repository:
rahulranjan94/rag-engineering-lab

Branch: $branch

Time: $successTime
"@

            try {
                [System.Windows.Forms.MessageBox]::Show(
                    $message,
                    "GitHub Auto-Sync - Upload Successful",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
            }
            catch {
                Write-Host "Push succeeded, but the notification failed."
                Write-Host $_.Exception.Message
            }
        }
    }
    catch {
        Write-Host "UNEXPECTED ERROR: $($_.Exception.Message)"
        Write-Host "The script will retry during the next cycle."
    }
    finally {
        Start-Sleep -Seconds $intervalSeconds
    }
}
