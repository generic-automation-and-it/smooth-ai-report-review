#requires -Version 7.2
<#
.SYNOPSIS
    Skills installer for Windows / macOS / Linux (PowerShell 7). Bash port: install-skills.sh.

.DESCRIPTION
    One-liner:
      irm https://raw.githubusercontent.com/generic-automation-and-it/smooth-ai-report-review/main/scripts/install-skills.ps1 | iex

    With switches (irm | iex cannot pass arguments):
      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/generic-automation-and-it/smooth-ai-report-review/main/scripts/install-skills.ps1))) -g -a

    Same contract as install-skills.sh; read scripts/SKILLS_INSTALLER.md.

      core      ai-review, git-commit-review-push       installed by default
      optional  ai-review-report, ai-analyse            only with -a (or installed:true in the manifest)

    The owned lists live in $OwnedCore / $OwnedOptional below AND in install-skills.sh;
    test-install-skills.sh holds the two ports to each other.

    Dependencies: PowerShell 7.2+, git.

    Environment overrides: SKILLS_REPO, SKILLS_BRANCH, SKILLS_ROOT, SMOOTH_AI_REVIEW_HOME,
    CLAUDE_CONFIG_DIR, CODEX_HOME, XDG_CONFIG_HOME (see install-skills.sh).

.EXAMPLE
    ./install-skills.ps1
    ./install-skills.ps1 -a
    ./install-skills.ps1 -g
    ./install-skills.ps1 -g -Uninstall
#>
[CmdletBinding()]
param(
    [Alias('a')]
    [switch] $All,
    [Alias('g')]
    [switch] $Global,
    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SkillsRepo = if ($env:SKILLS_REPO) { $env:SKILLS_REPO } else { 'https://github.com/generic-automation-and-it/smooth-ai-report-review.git' }
# $null -ne, not truthiness: an explicitly empty SKILLS_BRANCH means "the remote's default branch".
$SkillsBranch = if ($null -ne $env:SKILLS_BRANCH) { $env:SKILLS_BRANCH } else { 'main' }

$OwnedCore = @('ai-review', 'git-commit-review-push')
$OwnedOptional = @('ai-review-report', 'ai-analyse')

$StateDirName = '_smooth-ai-review-shared'
$Harnesses = @('claude-code', 'codex', 'opencode')
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Info { param([string] $Message) [Console]::Error.WriteLine("install-skills: $Message") }
function Fail { param([string] $Message) [Console]::Error.WriteLine("install-skills: $Message"); exit 1 }
function Get-UtcStamp { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH\:mm\:ssZ') }

# ---------------------------------------------------------------------------
# Owned set (A1-A3)
# ---------------------------------------------------------------------------

function Test-OwnedSkill {
    param([string] $Name)
    if (-not $Name -or $Name -match '[\\/]' -or $Name.Contains('..')) { return $false }
    foreach ($owned in @($OwnedCore + $OwnedOptional)) {
        if ($Name -ceq $owned) { return $true }
    }
    return $false
}

function Test-OptionalSkill {
    param([string] $Name)
    foreach ($owned in $OwnedOptional) { if ($Name -ceq $owned) { return $true } }
    return $false
}

function Get-OwnedSkills {
    param([string] $Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $names = [string[]] @(Get-ChildItem -LiteralPath $Dir -Directory -Force |
        Where-Object { (Test-OwnedSkill -Name $_.Name) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf) } |
        ForEach-Object { $_.Name })
    [Array]::Sort($names, [System.StringComparer]::Ordinal)
    return $names
}

# ---------------------------------------------------------------------------
# Manifest (B1-B6)
# ---------------------------------------------------------------------------

function Read-Manifest {
    # $null when missing (a first install). Empty, whitespace-only or unparseable is a hard error.
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { Fail "$Path is empty; fix or delete it - not treating it as a first install" }
    try { $data = $raw | ConvertFrom-Json -AsHashtable }
    catch { Fail "$Path is not valid JSON ($($_.Exception.Message)); fix or delete it - not treating it as a first install" }
    if ($data -isnot [System.Collections.IDictionary]) { Fail "$Path is not a JSON object; fix or delete it - not treating it as a first install" }
    return $data
}

function Get-Entry {
    param($Map, [string] $Key)
    if ($null -ne $Map -and $Map -is [System.Collections.IDictionary] -and $Map.Contains($Key)) { return $Map[$Key] }
    return $null
}

function Build-Skills {
    # New core skill -> true, new optional -> false (true with -a); the operator's flag is kept; -a turns
    # the optional skills on; names outside the catalogue are dropped.
    param($Existing, [string[]] $Catalog)
    $known = @{}
    foreach ($entry in @(Get-Entry $Existing 'skills')) {
        if ($entry -is [System.Collections.IDictionary] -and $entry['name'] -is [string]) {
            $known[$entry['name']] = [bool] (Get-Entry $entry 'installed')
        }
    }
    $names = [string[]] @($Catalog | Where-Object { $_ } | Select-Object -Unique)
    [Array]::Sort($names, [System.StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $names) {
        if ((Test-OptionalSkill $name) -and $All) { $flag = $true }
        elseif ($known.ContainsKey($name)) { $flag = $known[$name] }
        else { $flag = -not (Test-OptionalSkill $name) }
        $out.Add([ordered]@{ name = $name; installed = $flag })
    }
    return , $out
}

function Build-Harnesses {
    param($Existing)
    $found = Get-Entry $Existing 'harnesses'
    $out = [ordered]@{}
    foreach ($name in $Harnesses) {
        $value = Get-Entry $found $name
        $out[$name] = if ($null -eq $value) { $true } else { [bool] $value }
    }
    return $out
}

function Get-InstalledNames {
    param($Skills)
    @($Skills | Where-Object { $_['installed'] } | ForEach-Object { $_['name'] })
}

function Get-LinkTarget {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not $item.LinkType) { return $null }
    return [string] $item.Target
}

function Write-Manifest {
    # Fixed key order, ISO-8601 UTC. With Harnesses, the recorded links are merged by (type, path) and each
    # record's `enabled` is recomputed from disk.
    param([string] $Path, $Skills, $HarnessMap = $null, $Links = $null)
    $data = [ordered]@{ updated = (Get-UtcStamp) }
    if ($null -ne $HarnessMap) { $data['harnesses'] = $HarnessMap }
    $data['skills'] = @($Skills)
    if ($null -ne $HarnessMap) {
        $merged = [System.Collections.Generic.List[object]]::new()
        $index = @{}
        $previous = if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } else { $null }
        foreach ($rec in @(Get-Entry $previous 'links')) {
            if ($rec -is [System.Collections.IDictionary]) {
                $index["$($rec['type'])|$($rec['path'])"] = $merged.Count
                $merged.Add($rec)
            }
        }
        foreach ($rec in @($Links)) {
            if ($null -eq $rec) { continue }
            $key = "$($rec['type'])|$($rec['path'])"
            if ($index.ContainsKey($key)) { $merged[$index[$key]] = $rec }
            else { $index[$key] = $merged.Count; $merged.Add($rec) }
        }
        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($rec in $merged) {
            $ordered = [ordered]@{ type = $rec['type']; path = $rec['path']; detail = $rec['detail'] }
            $ordered['enabled'] = (Get-LinkTarget ([string] $rec['path'])) -eq [string] $rec['detail']
            $records.Add($ordered)
        }
        $data['links'] = @($records)
    }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, (($data | ConvertTo-Json -Depth 10) + "`n"), $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---------------------------------------------------------------------------
# Source clone and copy (G4)
# ---------------------------------------------------------------------------

function Invoke-SourceClone {
    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('install-skills-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    $repo = Join-Path $script:TempRoot 'repo'
    $url = $SkillsRepo -replace '\\', '/'
    if ($url -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        if (-not [System.IO.Path]::IsPathRooted($SkillsRepo)) { $url = (Join-Path (Get-Location).Path $SkillsRepo) -replace '\\', '/' }
        $url = if ($url.StartsWith('/')) { "file://$url" } else { "file:///$url" }
    }
    Write-Info "Cloning $SkillsRepo ($(if ($SkillsBranch) { $SkillsBranch } else { 'default branch' }))..."
    $gitArgs = @('-c', 'core.symlinks=true', 'clone', '--quiet', '--depth', '1')
    if ($SkillsBranch) { $gitArgs += @('--branch', $SkillsBranch) }
    $output = & git @gitArgs $url $repo 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($SkillsBranch) { Fail "failed to clone $SkillsRepo at '$SkillsBranch' (set SKILLS_BRANCH empty for the default branch) - $($output -join ' ')" }
        Fail "failed to clone $SkillsRepo - $($output -join ' ')"
    }
    $script:SourceSkills = Join-Path $repo '.agents/skills'
}

function Remove-TempRoot {
    if ((Test-Path variable:script:TempRoot) -and $script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-NonShippable {
    # Mirrors prune_non_shippable() in install-skills.sh.
    param([string] $Dest)
    foreach ($rel in 'AGENTS.md', 'scripts/eval', 'tests') {
        $p = Join-Path $Dest $rel
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }
    $stale = @(Get-ChildItem -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
            ($_.PSIsContainer -and $_.Name -ceq '__pycache__') -or
            (-not $_.PSIsContainer -and ($_.Name -clike 'test-*' -or $_.Name -ceq 'run-regressions.sh' -or $_.Name -ceq 'requirements-test.txt'))
        })
    foreach ($item in $stale) {
        if (Test-Path -LiteralPath $item.FullName) { Remove-Item -LiteralPath $item.FullName -Recurse -Force }
    }
}

function Install-Skill {
    param([string] $Name, [string] $DestRoot)
    if (-not (Test-OwnedSkill $Name)) { Write-Info "WARNING: $Name is not owned here - left untouched"; return }
    $source = Join-Path $script:SourceSkills $Name
    if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)) {
        Write-Info "WARNING: $Name not found in $SkillsRepo - left untouched"
        return
    }
    $dest = Join-Path $DestRoot $Name
    $item = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        if ($item.LinkType) {
            # Delete() removes the link itself, never its target.
            Write-Info "Replacing link $dest -> $($item.Target) with an installed copy"
            $item.Delete()
        }
        else { Remove-Item -LiteralPath $dest -Recurse -Force }
    }
    Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
    Remove-NonShippable -Dest $dest
    Write-Info "Updated $Name"
}

function Get-Catalog {
    param([string] $DestRoot)
    @(Get-OwnedSkills $script:SourceSkills) + @(Get-OwnedSkills $DestRoot)
}

# ---------------------------------------------------------------------------
# Per-repo install (G1-G3)
# ---------------------------------------------------------------------------

function Find-SkillsRoot {
    foreach ($dir in '.agents/skills', '.claude/skills', '.codex/skills') {
        if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
    }
    Fail 'no skills directory found - expected one of .agents/skills, .claude/skills, .codex/skills (create one, or set SKILLS_ROOT)'
}

function Write-GatePrecedenceWarning {
    param([string] $SkillsRoot, [string[]] $Names)
    if ($Names -notcontains 'ai-review-report') { return }
    if (-not (Test-Path -LiteralPath '.agents/skills' -PathType Container)) { return }
    if ((Resolve-Path -LiteralPath $SkillsRoot).Path -ne (Resolve-Path -LiteralPath '.agents/skills').Path) { return }
    $callers = @(Get-ChildItem -Path '.github/workflows' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.yml', '.yaml' } |
        Where-Object { Select-String -LiteralPath $_.FullName -Pattern 'smooth-ai-report-review/\.github/workflows/pipeline-(code-review-report|ai-analyse)\.yml@' -Quiet })
    if ($callers.Count -eq 0) { return }
    Write-Info 'WARNING: .agents/skills/ai-review-report now exists, so the reusable review gate runs this copy'
    Write-Info '         instead of the tooling pinned by its @ref. Re-run with -a to keep it current, or set it'
    Write-Info '         installed:false and delete the folder to go back to the pinned tooling.'
}

function Invoke-RepoInstall {
    if ($env:SKILLS_ROOT) {
        if (-not (Test-Path -LiteralPath $env:SKILLS_ROOT -PathType Container)) { Fail "SKILLS_ROOT '$($env:SKILLS_ROOT)' does not exist" }
        $skillsRoot = $env:SKILLS_ROOT
    }
    else { $skillsRoot = Find-SkillsRoot }
    # Absolute: .NET file APIs resolve relative paths against the process directory, not the PS location.
    $skillsRoot = (Resolve-Path -LiteralPath $skillsRoot).Path
    $manifest = Join-Path (Join-Path $skillsRoot $StateDirName) 'installation.json'
    Write-Info "Skills root: $skillsRoot"

    $existing = Read-Manifest $manifest
    Invoke-SourceClone
    $skills = Build-Skills -Existing $existing -Catalog (Get-Catalog $skillsRoot)
    $names = @(Get-InstalledNames $skills)
    if ($names.Count -eq 0) { Write-Info 'No skills marked installed:true - nothing to update.' }
    foreach ($name in $names) { Install-Skill -Name $name -DestRoot $skillsRoot }
    Write-GatePrecedenceWarning -SkillsRoot $skillsRoot -Names $names

    New-Item -ItemType Directory -Path (Split-Path -Parent $manifest) -Force | Out-Null
    Write-Manifest -Path $manifest -Skills $skills
    Write-Info "Done. State: $manifest"
}

# ---------------------------------------------------------------------------
# Global install (-g): store + symlinks (D1-D7)
# ---------------------------------------------------------------------------

function Resolve-GlobalPaths {
    $root = if ($env:SMOOTH_AI_REVIEW_HOME) { $env:SMOOTH_AI_REVIEW_HOME } else { Join-Path $HOME '.smooth-ai-review' }
    if (-not [System.IO.Path]::IsPathRooted($root)) {
        Fail "SMOOTH_AI_REVIEW_HOME must be an absolute path (got '$root') - links into a relative store would dangle"
    }
    $trimmed = $root.TrimEnd('/', '\')
    $script:GlbRoot = if ($trimmed) { $trimmed } else { $root }
    $script:GlobalManifest = Join-Path $script:GlbRoot 'installation.json'
}

function Get-ToolDir {
    param([string] $Tool)
    switch ($Tool) {
        'claude-code' { if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' } }
        'codex' { if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' } }
        'opencode' { Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }) 'opencode' }
    }
}

function Remove-StoreLinks {
    # Found on disk, not from records (D3); anything not pointing into the store is never touched (D4).
    param([string] $Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    $prefix = (Join-Path $script:GlbRoot 'skills') + [System.IO.Path]::DirectorySeparatorChar
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force)) {
        if ($item.LinkType -and ([string] $item.Target).StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $item.Delete()
            Write-Info "Unlinked $($item.FullName) (tool turned off)"
        }
    }
}

function New-SkillLink {
    # Create only when nothing is there; keep and re-record a correct link. Without symlink rights on
    # Windows a directory junction is the (degraded) fallback.
    param([string] $Link, [string] $Target, [string] $Type)
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        if ($item.LinkType -and ([string] $item.Target) -eq $Target) {
            $script:Links.Add([ordered]@{ type = $Type; path = $Link; detail = $Target })
        }
        elseif ($item.LinkType) { Write-Info "WARNING: $Link is a link to somewhere else - left untouched" }
        else { Write-Info "WARNING: $Link already exists - left untouched" }
        return
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Link) -Force | Out-Null
    try { New-Item -ItemType SymbolicLink -Path $Link -Target $Target -ErrorAction Stop | Out-Null }
    catch {
        try { New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null }
        catch { Write-Info "WARNING: could not create $Link -> $Target - left untouched"; return }
    }
    $script:Links.Add([ordered]@{ type = $Type; path = $Link; detail = $Target })
    Write-Info "Linked $Link -> $Target"
}

function Invoke-GlobalInstall {
    $existing = Read-Manifest $script:GlobalManifest
    $store = Join-Path $script:GlbRoot 'skills'
    New-Item -ItemType Directory -Path $store -Force | Out-Null
    Invoke-SourceClone

    $harnessMap = Build-Harnesses $existing
    $skills = Build-Skills -Existing $existing -Catalog (Get-Catalog $store)
    $names = @(Get-InstalledNames $skills)
    if ($names.Count -eq 0) { Write-Info 'No skills marked installed:true - nothing to update.' }
    foreach ($name in $names) { Install-Skill -Name $name -DestRoot $store }

    $script:Links = [System.Collections.Generic.List[object]]::new()
    foreach ($tool in $Harnesses) {
        $dir = Get-ToolDir $tool
        if (-not $harnessMap[$tool]) {
            Write-Info "Tool $tool is off - removing what this installer linked"
            Remove-StoreLinks (Join-Path $dir 'skills')
            continue
        }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Info "$tool not found ($dir) - skipped"; continue }
        foreach ($name in $names) {
            New-SkillLink -Link (Join-Path (Join-Path $dir 'skills') $name) -Target (Join-Path $store $name) -Type "$tool-skill"
        }
    }

    Write-Manifest -Path $script:GlobalManifest -Skills $skills -HarnessMap $harnessMap -Links $script:Links
    Write-Info "Done. State: $($script:GlobalManifest)"
}

function Invoke-GlobalUninstall {
    if (-not (Test-Path -LiteralPath $script:GlobalManifest -PathType Leaf)) {
        Write-Info "No global install at $($script:GlobalManifest) - nothing to uninstall"
        return
    }
    $data = Read-Manifest $script:GlobalManifest
    foreach ($rec in @(Get-Entry $data 'links')) {
        if ($rec -isnot [System.Collections.IDictionary]) { continue }
        $path = [string] $rec['path']
        if (-not $path) { continue }
        if ((Get-LinkTarget $path) -eq [string] $rec['detail']) {
            (Get-Item -LiteralPath $path -Force).Delete()
            Write-Info "Removed $path"
        }
    }
    $out = [ordered]@{}
    foreach ($key in $data.Keys) { $out[$key] = $data[$key] }
    $out['updated'] = Get-UtcStamp
    $out['links'] = @()
    [System.IO.File]::WriteAllText($script:GlobalManifest, (($out | ConvertTo-Json -Depth 10) + "`n"), $Utf8NoBom)
    Write-Info "Uninstalled - store left at $($script:GlbRoot) (delete it to reclaim space)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($Uninstall -and -not $Global) { Fail '-Uninstall only applies to the global install - use: install-skills.ps1 -g -Uninstall' }
if ($Uninstall -and $All) { Fail '-a has no meaning with -Uninstall' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'git is required' }

try {
    if ($Global) {
        if ($env:SKILLS_ROOT) { Fail '-g cannot be combined with SKILLS_ROOT - the global install owns its own store' }
        Resolve-GlobalPaths
        if ($Uninstall) { Invoke-GlobalUninstall } else { Invoke-GlobalInstall }
    }
    else { Invoke-RepoInstall }
}
finally { Remove-TempRoot }
