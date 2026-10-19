
# RAG Engineering Lab - GitHub Auto Sync
# Checks for changes every 2 minutes

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

# Verify repository and branch
git rev-parse --is-inside-work-tree
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not a Git repository."
    exit 1
}

$branch = git branch --show-current
if ($branch -ne "master") {
    Write-Host "Expected master branch, found: $branch"
    exit 1
}

Write-Host "Auto-sync started for rag-engineering-lab."
Write-Host "Branch: master | Interval: 120 seconds"
Write-Host "Press Ctrl+C to stop."

while ($true) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "`n[$timestamp] Checking changes..."

    # Stage eligible new, modified, and deleted files
    git add -A

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Staging failed. Check Git output."
    }
    else {
        # Detect staged changes
        git diff --cached --quiet
        $diffResult = $LASTEXITCODE

        if ($diffResult -eq 1) {
            git commit -m "Auto-sync: $timestamp"

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Commit created."
            }
            else {
                Write-Host "Commit failed. Review the error."
            }
        }
        elseif ($diffResult -eq 0) {
            Write-Host "No changes to commit."
        }
        else {
            Write-Host "Unable to check staged changes."
        }

        # Push local commits to the configured GitHub remote
        git push origin master

        if ($LASTEXITCODE -eq 0) {
            Write-Host "GitHub push successful."
        }
        else {
            Write-Host "Push failed. Check the error above."
        }
    }

    Start-Sleep -Seconds 120
}
