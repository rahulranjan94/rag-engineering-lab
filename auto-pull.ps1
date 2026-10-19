
# ============================================================
# RAG Engineering Lab - GitHub to Laptop Auto-Sync
# Checks GitHub every 2 minutes and safely downloads new commits.
#
# Device: Laptop1:Bengaluru_system
# Repository: rahulranjan94/rag-engineering-lab
# Branch: master
#
# Safety principles:
# 1. Never discard local changes.
# 2. Detect modified, staged, and untracked files.
# 3. Use fast-forward-only updates.
# 4. Stop when local and remote histories have diverged.
# 5. Show success only after a successful update.
# ============================================================

$ErrorActionPreference = "Stop"

# -------------------- Configuration --------------------------

$branch = "master"
$device = "Laptop1:Bengaluru_system"
$repository = "rahulranjan94/rag-engineering-lab"
$remote = "origin"
$intervalSeconds = 120

# -------------------- Windows notification -------------------

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
}
catch {
    Write-Host "ERROR: Windows notification support could not be loaded."
    Write-Host $_.Exception.Message
    exit 1
}

# -------------------- Helper functions -----------------------

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GitArgs
    )

    $output = & git @GitArgs 2>&1
    $exitCode = $LASTEXITCODE

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = @($output | ForEach-Object { "$_" })
    }
}

function Write-Log {
    param([string]$Message)

    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$time] $Message"
}

# -------------------- Startup checks -------------------------

try {
    $gitVersion = Invoke-Git -GitArgs @("--version")

    if ($gitVersion.ExitCode -ne 0) {
        throw "Git is not installed or is not available in PATH."
    }

    Set-Location -LiteralPath $PSScriptRoot

    $repoCheck = Invoke-Git -GitArgs @(
        "rev-parse", "--is-inside-work-tree"
    )

    if ($repoCheck.ExitCode -ne 0 -or
        ($repoCheck.Output -join "").Trim() -ne "true") {
        throw "The script folder is not inside a Git working tree."
    }

    $branchResult = Invoke-Git -GitArgs @(
        "branch", "--show-current"
    )

    if ($branchResult.ExitCode -ne 0) {
        throw "Could not determine the current Git branch."
    }

    if (($branchResult.Output -join "").Trim() -ne $branch) {
        throw "Expected branch '$branch'. Switch to the correct branch and restart."
    }

    $remoteResult = Invoke-Git -GitArgs @(
        "remote", "get-url", $remote
    )

    if ($remoteResult.ExitCode -ne 0) {
        throw "Remote '$remote' is not configured."
    }

    $remoteUrl = ($remoteResult.Output -join "").Trim()

    if ($remoteUrl -notmatch
        '(^|[:/])rahulranjan94/rag-engineering-lab(\.git)?$') {
        throw "Remote '$remote' does not appear to point to $repository. URL: $remoteUrl"
    }

    # Ensure the remote-tracking branch exists before starting.
    $trackingCheck = Invoke-Git -GitArgs @(
        "show-ref", "--verify", "--quiet",
        "refs/remotes/$remote/$branch"
    )

    if ($trackingCheck.ExitCode -ne 0) {
        Write-Log "Remote-tracking branch not found yet; it will be created by fetch."
    }
}
catch {
    Write-Host "STARTUP ERROR: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "GitHub-to-laptop auto-sync started."
Write-Host "Device: $device"
Write-Host "Repository: $repository"
Write-Host "Branch: $branch"
Write-Host "Interval: $intervalSeconds seconds"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

# -------------------- Main monitoring loop -------------------

while ($true) {
    try {
        Write-Log "Checking GitHub..."

        # Fetch the exact branch into origin/master.
        # Fetch downloads history; it does not update working files.
        $fetch = Invoke-Git -GitArgs @(
            "fetch", $remote,
            "refs/heads/$branch`:refs/remotes/$remote/$branch"
        )

        if ($fetch.ExitCode -ne 0) {
            Write-Log "FETCH FAILED. Check network, GitHub authentication, and remote configuration."

            foreach ($line in $fetch.Output) {
                Write-Host "  $line"
            }

            continue
        }

        # Detect modified, staged, and untracked files.
        $status = Invoke-Git -GitArgs @(
            "status", "--porcelain", "--untracked-files=all"
        )

        if ($status.ExitCode -ne 0) {
            Write-Log "Could not inspect the local working tree. Skipping this cycle."
            continue
        }

        if ($status.Output.Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace(($status.Output -join ""))) {
            Write-Log "LOCAL CHANGES DETECTED. Update skipped to protect your work."
            Write-Host "Commit, stash, or otherwise safely resolve local changes before syncing."
            continue
        }

        # Do not update while a Git operation is in progress.
        $operationMarkers = @(
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "rebase-merge",
            "rebase-apply",
            "BISECT_LOG"
        )

        $operationInProgress = $false

        foreach ($marker in $operationMarkers) {
            $markerCheck = Invoke-Git -GitArgs @(
                "rev-parse", "--git-path", $marker
            )

            if ($markerCheck.ExitCode -eq 0) {
                $markerPath = ($markerCheck.Output -join "").Trim()

                if (-not [System.IO.Path]::IsPathRooted($markerPath)) {
                    $markerPath = Join-Path (Get-Location) $markerPath
                }

                if (Test-Path -LiteralPath $markerPath) {
                    Write-Log "Git operation in progress ($marker). Update skipped."
                    $operationInProgress = $true
                    break
                }
            }
        }

        if ($operationInProgress) {
            continue
        }

        # Count commits on the local branch that are not on GitHub.
        $aheadResult = Invoke-Git -GitArgs @(
            "rev-list", "--count", "$remote/$branch..HEAD"
        )

        if ($aheadResult.ExitCode -ne 0) {
            Write-Log "Could not compare local history with GitHub."
            continue
        }

        # Count commits on GitHub that are not in the local branch.
        $behindResult = Invoke-Git -GitArgs @(
            "rev-list", "--count", "HEAD..$remote/$branch"
        )

        if ($behindResult.ExitCode -ne 0) {
            Write-Log "Could not compare remote history with the local branch."
            continue
        }

        $aheadCount = 0
        $behindCount = 0

        if (-not [int]::TryParse(
            ($aheadResult.Output -join "").Trim(),
            [ref]$aheadCount
        )) {
            Write-Log "Invalid local commit count. Skipping this cycle."
            continue
        }

        if (-not [int]::TryParse(
            ($behindResult.Output -join "").Trim(),
            [ref]$behindCount
        )) {
            Write-Log "Invalid remote commit count. Skipping this cycle."
            continue
        }

        # Divergence means both sides contain unique commits.
        if ($aheadCount -gt 0 -and $behindCount -gt 0) {
            Write-Log "HISTORY DIVERGED: local and GitHub branches both have unique commits."
            Write-Log "Automatic update stopped for this cycle. Resolve the histories manually."
            continue
        }

        if ($behindCount -eq 0) {
            if ($aheadCount -gt 0) {
                Write-Log "Local branch is ahead of GitHub by $aheadCount commit(s). No download needed."
            }
            else {
                Write-Log "Laptop is already up to date."
            }

            continue
        }

        # Confirm the update can be a fast-forward only.
        Write-Log "GitHub has $behindCount new commit(s). Applying safe fast-forward update..."

        $merge = Invoke-Git -GitArgs @(
            "merge", "--ff-only", "$remote/$branch"
        )

        if ($merge.ExitCode -ne 0) {
            Write-Log "UPDATE FAILED. No automatic reset or force operation was attempted."

            foreach ($line in $merge.Output) {
                Write-Host "  $line"
            }

            Write-Log "Review the repository state before trying again."
            continue
        }

        # Show success only after Git confirms the update succeeded.
        $successTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        $message = @"
GitHub changes downloaded successfully!

Device: $device

GitHub repository:
$repository

Branch: $branch

Commits downloaded: $behindCount

Time: $successTime
"@

        Write-Log "UPDATE SUCCESSFUL. Downloaded $behindCount commit(s)."

        try {
            [System.Windows.Forms.MessageBox]::Show(
                $message,
                "GitHub Auto-Sync - Download Successful",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
        catch {
            Write-Log "Update succeeded, but the notification could not be displayed."
            Write-Host $_.Exception.Message
        }
    }
    catch {
        Write-Log "UNEXPECTED ERROR: $($_.Exception.Message)"
        Write-Log "The script will retry during the next cycle."
    }
    finally {
        Start-Sleep -Seconds $intervalSeconds
    }
}
