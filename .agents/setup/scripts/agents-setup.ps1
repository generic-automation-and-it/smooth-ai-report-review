# AI Agent Tools symlink setup for Windows
# Supports: Claude Code, GitHub Copilot, Cursor, OpenAI Codex
# Requires: Administrator privileges

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script requires administrator privileges. Please run PowerShell as Administrator."
    exit 1
}

# Get the repo root (parent of .agents)
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Set-Location $repoRoot

# Helper function to create symlink
function Create-Symlink {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [bool]$IsDirectory = $false
    )

    # Remove existing symlink/file if it exists. A directory symlink needs rmdir
    # (Remove-Item without -Recurse fails on it, and -Recurse would delete the
    # link TARGET's contents); a real directory is never deleted — bail instead.
    if (Test-Path -LiteralPath $LinkPath) {
        $existing = Get-Item -LiteralPath $LinkPath -Force
        if ($existing.LinkType) {
            if ($existing.PSIsContainer) {
                cmd /c rmdir "$LinkPath" | Out-Null
            } else {
                Remove-Item -LiteralPath $LinkPath -Force
            }
        } elseif ($existing.PSIsContainer) {
            Write-Error "Refusing to replace real directory '$LinkPath' with a symlink - remove it manually first."
            return $false
        } else {
            # Plain file (e.g. a symlink checked out with core.symlinks=false)
            Remove-Item -LiteralPath $LinkPath -Force
        }
    }

    # Create symlink
    if ($IsDirectory) {
        cmd /c mklink /D "$LinkPath" "$TargetPath" | Out-Null
    } else {
        cmd /c mklink "$LinkPath" "$TargetPath" | Out-Null
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] $LinkPath -> $TargetPath" -ForegroundColor Green
        return $true
    } else {
        Write-Error "Failed to create symlink: $LinkPath -> $TargetPath"
        return $false
    }
}

$allSuccess = $true

# Create directory symlinks for tool-specific rule paths
Write-Host "Creating directory symlinks for AI agent tools..." -ForegroundColor Cyan
$allSuccess = (Create-Symlink ".claude" ".agents" $true) -and $allSuccess
$allSuccess = (Create-Symlink ".codex" ".agents" $true) -and $allSuccess

# Recreate the committed Claude Code plugin skills symlink (skills -> .agents/skills).
# A clone made without core.symlinks=true checks it out as a plain text file
# containing the target path; replace it with a real directory symlink.
$allSuccess = (Create-Symlink "skills" ".agents\skills" $true) -and $allSuccess

# Create file symlinks for context files
Write-Host "`nCreating file symlinks for context files..." -ForegroundColor Cyan
$allSuccess = (Create-Symlink "CLAUDE.md" "AGENTS.md") -and $allSuccess

# Configure git to handle symlinks properly
if ($allSuccess) {
    Write-Host "`nConfiguring git for symlink support..." -ForegroundColor Cyan
    git config core.symlinks true
    Write-Host "[OK] Git configured for symlinks" -ForegroundColor Green
    Write-Host "`nAll symlinks created successfully" -ForegroundColor Green
    exit 0
} else {
    Write-Error "One or more symlinks failed. Ensure you have administrator privileges and .agents exists."
    exit 1
}
