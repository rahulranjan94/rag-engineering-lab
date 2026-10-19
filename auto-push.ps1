
# RAG Engineering Lab - GitHub Auto Sync
# Checks for changes every 2 minutes
# Shows a Windows dialog after a successful push with new changes

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

# Windows dialog support
Add-Type -AssemblyName System.Windows.Forms

# Verify repository
git rev-parse --is-inside-work-tree | Out-Null
if ($LASTEXITCODE -ne 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "This folder is not a Git repository.",
        "GitHub Auto-Sync - Error",
        "OK",
        "Error"
    ) | Out-Null
    exit 1
}

# Verify branch
$branch = git branch --show-current
if ($branch -ne "master") {
    Write-Host "Expected master branch, found: $branch"
    exit 1
}

Write-Host "Auto-sync started for rag-engineering-lab."
Write-Host "Device: Laptop1:Bengaluru_system"
Write-Host "Branch: master | Interval: 120 seconds"
Write-Host "Press Ctrl+C to stop."

while ($true) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "`n[$timestamp] Checking changes..."

    $commitCreated = $false

    # Stage eligible new, modified, and deleted files
    git add -A

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Staging failed. Check Git output."
    }
    else {
        # Check for staged changes
        git diff --cached --quiet
        $diffResult = $LASTEXITCODE

        if ($diffResult -eq 1) {
            git commit -m "Auto-sync: $timestamp"

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Commit created."
                $commitCreated = $true
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

        # Push local commits to GitHub
        # Capture and display Git's output
        $pushOutput = git push origin master 2>&1
        $pushExitCode = $LASTEXITCODE

        $pushOutput | ForEach-Object {
            Write-Host $_
        }

        if ($pushExitCode -eq 0) {
            Write-Host "GitHub push successful."

            # Show dialog only when a new commit was created
            # and the push succeeded
            if ($commitCreated) {
                $message = @"
Your code has been pushed successfully!

Device: Laptop1:Rahul@Bengaluru_system

GitHub Repository:
rahulranjan94/rag-engineering-lab

Branch: master

Time: $timestamp
"@

                [System.Windows.Forms.MessageBox]::Show(
                    $message,
                    "GitHub Auto-Sync - Upload Successful",
                    "OK",
                    "Information"
                ) | Out-Null
            }
        }
        else {
            Write-Host "Push failed. Check the error above."
        }
    }

    Start-Sleep -Seconds 120
}
