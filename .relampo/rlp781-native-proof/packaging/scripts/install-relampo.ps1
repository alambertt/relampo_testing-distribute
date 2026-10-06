<#
.SYNOPSIS
  Installs the relampo CLI from a local dist directory or a GitHub Release archive.

.DESCRIPTION
  Mirrors the behavior of scripts/install-relampo.sh:
  - If --local (or $env:RELAMPO_LOCAL_DIR) contains relampo_<os>_<arch>[.exe], installs from there.
  - Otherwise downloads a release archive from GitHub Releases (or --url / $env:RELAMPO_URL).
  - If no version/tag provided, uses latest GitHub Release tag.
  - On Windows, this script must be run from an elevated PowerShell session.

.PARAMETER Version
  Version (e.g. 1.2.3). If empty, uses latest release.

.PARAMETER Dir
  Install directory.

.PARAMETER Url
  Full URL to the release archive.

.PARAMETER Repo
  GitHub repo in owner/name format.

.PARAMETER Local
  Local folder with relampo_<os>_<arch> binaries.

.ENVIRONMENT
  RELAMPO_VERSION     Version (e.g. 1.2.3). If empty, uses latest release.
  RELAMPO_TAG         Release tag (e.g. v1.2.3). Overrides RELAMPO_VERSION.
  RELAMPO_REPO        GitHub repo in owner/name format. Default: sqaadvisory-labs/relampo-backend
  RELAMPO_URL         Full URL to the archive. Overrides repo/version detection.
  RELAMPO_BASE_URL    Base URL where archives live (release folder).
  RELAMPO_LATEST_URL  URL used to resolve the latest version.
  RELAMPO_LOCAL_DIR   Local folder with relampo_<os>_<arch> binaries.
  RELAMPO_INSTALL_DIR Install directory (default varies by OS).

.EXAMPLE
  ./scripts/install-relampo.ps1 -Local "C:\path\to\dist"

.EXAMPLE
  ./scripts/install-relampo.ps1 -Version 0.0.1
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$Version,

  [Parameter(Mandatory = $false)]
  [string]$Dir,

  [Parameter(Mandatory = $false)]
  [string]$Url,

  [Parameter(Mandatory = $false)]
  [string]$Repo,

  [Parameter(Mandatory = $false)]
  [string]$Local,

  [Parameter(Mandatory = $false)]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$script:WindowsDefenderWarningShown = $false

function Show-Usage {
  @'
Usage: install-relampo.ps1 [-Version VERSION] [-Dir DIR] [-Url URL] [-Repo OWNER/REPO] [-Local DIR]

Installs the relampo CLI from a release archive.
On Windows, this script must be run from an elevated PowerShell session.

Environment variables:
  RELAMPO_VERSION     Version (e.g. 1.2.3). If empty, uses latest release.
  RELAMPO_TAG         Release tag (e.g. v1.2.3). Overrides RELAMPO_VERSION.
  RELAMPO_REPO        GitHub repo in owner/name format. Default: sqaadvisory-labs/relampo-backend
  RELAMPO_URL         Full URL to the archive. Overrides repo/version detection.
  RELAMPO_BASE_URL    Base URL where archives live (release folder).
  RELAMPO_LATEST_URL  URL used to resolve the latest version.
  RELAMPO_LOCAL_DIR   Local folder with relampo_<os>_<arch> binaries.
  RELAMPO_INSTALL_DIR Install directory (default varies by OS).
'@ | Write-Host
}

if ($Help) {
  Show-Usage
  exit 0
}

# Inputs / env fallbacks
$binBaseName = 'relampo'

if (-not $Repo -or $Repo.Trim().Length -eq 0) {
  $Repo = $env:RELAMPO_REPO
}
if (-not $Repo -or $Repo.Trim().Length -eq 0) {
  $Repo = 'sqaadvisory-labs/relampo-backend'
}

$tag = $env:RELAMPO_TAG
if (-not $Version -or $Version.Trim().Length -eq 0) {
  $Version = $env:RELAMPO_VERSION
}

if (-not $Url -or $Url.Trim().Length -eq 0) {
  $Url = $env:RELAMPO_URL
}

$baseUrl = $env:RELAMPO_BASE_URL
if (-not $baseUrl -or $baseUrl.Trim().Length -eq 0) {
  $baseUrl = 'https://dl.relampo.com/relampo'
}

$latestUrl = $env:RELAMPO_LATEST_URL
if (-not $latestUrl -or $latestUrl.Trim().Length -eq 0) {
  $latestUrl = 'https://dl.relampo.com/relampo/latest.txt'
}

if (-not $Local -or $Local.Trim().Length -eq 0) {
  $Local = $env:RELAMPO_LOCAL_DIR
}

if (-not $Dir -or $Dir.Trim().Length -eq 0) {
  $Dir = $env:RELAMPO_INSTALL_DIR
}

function Detect-Os {
  # $IsWindows/$IsMacOS/$IsLinux only exist in PowerShell Core 6+; PS 5.1 is Windows-only
  if ($null -ne $IsWindows) {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS)   { return 'darwin' }
    if ($IsLinux)   { return 'linux' }
    throw "Unsupported OS."
  }
  return 'windows'
}

function Detect-Arch {
  $archCandidates = @()

  try {
    $runtimeArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($null -ne $runtimeArch) {
      $runtimeArchStr = $runtimeArch.ToString()
      if ($runtimeArchStr -and $runtimeArchStr.Trim().Length -gt 0) {
        $archCandidates += $runtimeArchStr.Trim()
      }
    }
  } catch {
    # Ignore and fallback to env vars below
  }

  if ($env:PROCESSOR_ARCHITEW6432 -and $env:PROCESSOR_ARCHITEW6432.Trim().Length -gt 0) {
    $archCandidates += $env:PROCESSOR_ARCHITEW6432.Trim()
  }
  if ($env:PROCESSOR_ARCHITECTURE -and $env:PROCESSOR_ARCHITECTURE.Trim().Length -gt 0) {
    $archCandidates += $env:PROCESSOR_ARCHITECTURE.Trim()
  }

  foreach ($candidate in $archCandidates) {
    switch ($candidate.ToUpperInvariant()) {
      'X64' { return 'amd64' }
      'AMD64' { return 'amd64' }
      'ARM64' { return 'arm64' }
      'AARCH64' { return 'arm64' }
      'X86' { throw "Unsupported architecture: x86 (please run 64-bit PowerShell)." }
    }
  }

  $raw = ($archCandidates -join ', ').Trim()
  if (-not $raw) { $raw = '<unknown>' }
  throw "Unsupported architecture: $raw"
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Path-ContainsDir([string]$Candidate) {
  return Path-ValueContainsDir -PathValue $env:PATH -Candidate $Candidate
}

function Get-NormalizedPath([string]$Path) {
  if (-not $Path) { return '' }
  try {
    return (Resolve-Path -LiteralPath $Path).Path
  } catch {
    return [System.IO.Path]::GetFullPath($Path)
  }
}

function Path-ValueContainsDir([string]$PathValue, [string]$Candidate) {
  if (-not $Candidate) { return $false }
  $candidateNormalized = Get-NormalizedPath -Path $Candidate
  if (-not $candidateNormalized) { return $false }
  $sep = [System.IO.Path]::PathSeparator
  $parts = ($PathValue -split [regex]::Escape($sep)) | Where-Object { $_ -ne '' }
  foreach ($p in $parts) {
    try {
      $entryNormalized = Get-NormalizedPath -Path $p
      if ([string]::Equals($entryNormalized, $candidateNormalized, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    } catch {
      # ignore invalid entries
    }
  }
  return $false
}

function Ensure-UserPathContainsDir([string]$InstallDir) {
  $resolvedInstallDir = Get-NormalizedPath -Path $InstallDir
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $updated = $false

  if (-not (Path-ValueContainsDir -PathValue $userPath -Candidate $resolvedInstallDir)) {
    if ($userPath -and $userPath.Trim().Length -gt 0) {
      $newUserPath = "$resolvedInstallDir;$userPath"
    } else {
      $newUserPath = $resolvedInstallDir
    }
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    $updated = $true
  }

  if (-not (Path-ValueContainsDir -PathValue $env:PATH -Candidate $resolvedInstallDir)) {
    if ($env:PATH -and $env:PATH.Trim().Length -gt 0) {
      $env:PATH = "$resolvedInstallDir;$env:PATH"
    } else {
      $env:PATH = $resolvedInstallDir
    }
  }

  return $updated
}

function Test-IsAdministrator {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity) {
      return $false
    }

    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Show-WindowsDefenderWarning([string]$InstallDir) {
  if ($script:WindowsDefenderWarningShown) {
    return
  }

  $resolvedDir = [System.IO.Path]::GetFullPath($InstallDir)
  Write-Host ""
  Write-Host "WARNING: Windows Defender exclusions could not be managed automatically." -ForegroundColor Yellow
  Write-Host "If installation fails with a virus/malware error, this is a false positive" -ForegroundColor Yellow
  Write-Host "common with Go binaries. To fix, run ONE of:" -ForegroundColor Yellow
  Write-Host "  1. Re-run this script as Administrator" -ForegroundColor Cyan
  Write-Host "  2. Manually add an exclusion: Windows Security > Virus & threat protection" -ForegroundColor Cyan
  Write-Host "     > Manage settings > Exclusions > Add '$resolvedDir'" -ForegroundColor Cyan
  Write-Host ""

  $script:WindowsDefenderWarningShown = $true
}

function Warn-IfWindowsDefenderNeedsManualSetup([string]$InstallDir) {
  $onWindows = ($null -eq $IsWindows) -or $IsWindows
  if (-not $onWindows) {
    return
  }

  if (-not (Test-IsAdministrator)) {
    Show-WindowsDefenderWarning -InstallDir $InstallDir
  }
}

function Test-WindowsDefenderExclusionExists([string]$Path) {
  try {
    $preferences = Get-MpPreference -ErrorAction Stop
    if ($null -eq $preferences -or $null -eq $preferences.ExclusionPath) {
      return $false
    }

    foreach ($existingPath in $preferences.ExclusionPath) {
      if ([string]::Equals($existingPath, $Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    }

    return $false
  } catch {
    return $null
  }
}

function Install-Bin([string]$SrcPath, [string]$InstallDir, [string]$InstallName) {
  Ensure-Dir -Path $InstallDir
  $dest = Join-Path $InstallDir $InstallName

  $onWindows = ($null -eq $IsWindows) -or $IsWindows

  # Exclude both source and destination files from Defender to prevent false positives
  $binExclusions = @()
  if ($onWindows) {
    foreach ($exclPath in @($SrcPath, $dest)) {
      $exclusionAlreadyExists = Test-WindowsDefenderExclusionExists -Path $exclPath
      try {
        Add-MpPreference -ExclusionPath $exclPath -ErrorAction Stop
        if ($false -eq $exclusionAlreadyExists) {
          $binExclusions += $exclPath
        }
      } catch {
        Show-WindowsDefenderWarning -InstallDir $InstallDir
      }
    }
  }

  try {
    Copy-Item -LiteralPath $SrcPath -Destination $dest -Force
  } finally {
    # Clean up file-level exclusions immediately after copy
    foreach ($exclPath in $binExclusions) {
      try { Remove-MpPreference -ExclusionPath $exclPath -ErrorAction SilentlyContinue } catch { }
    }
  }
  if (-not $onWindows) {
    try {
      & chmod 0755 $dest | Out-Null
    } catch {
      # best-effort
    }
  }

  Write-Host "Installed to $dest"
  if (-not (Path-ContainsDir -Candidate $InstallDir)) {
    if ($onWindows) {
      if (Ensure-UserPathContainsDir -InstallDir $InstallDir) {
        Write-Host "Added $InstallDir to the user PATH automatically."
      } else {
        Write-Host "PATH already includes $InstallDir for future PowerShell sessions."
      }
      Write-Host "Open a new PowerShell window if relampo is not available in this one yet."
    } else {
      Write-Host "Add this to your shell profile:"
      Write-Host "  export PATH=\"$($InstallDir):`$PATH\""
    }
  }
  Write-Host "Run: relampo version"
}

function Invoke-HttpJson([string]$RequestUrl) {
  # GitHub API requires a UA header
  $headers = @{ 'User-Agent' = 'relampo-installer' }
  return Invoke-RestMethod -Headers $headers -Uri $RequestUrl -Method Get
}

function Test-HttpOk([string]$RequestUrl) {
  try {
    $headers = @{ 'User-Agent' = 'relampo-installer' }
    Invoke-WebRequest -Headers $headers -Uri $RequestUrl -Method Get -MaximumRedirection 0 -UseBasicParsing | Out-Null
    return $true
  } catch {
    # Any non-2xx should be treated as not ok
    return $false
  }
}

function Download-File([string]$RequestUrl, [string]$OutFile) {
  $headers = @{ 'User-Agent' = 'relampo-installer' }
  Invoke-WebRequest -Headers $headers -Uri $RequestUrl -OutFile $OutFile -UseBasicParsing
}

$os = Detect-Os
$arch = Detect-Arch

$ext = ''
$archiveExt = 'tar.gz'
$installName = $binBaseName

if ($os -eq 'windows') {
  $ext = '.exe'
  $archiveExt = 'zip'
  $installName = 'relampo.exe'
}

# Default install dir (mirrors the intent of the sh script; avoid requiring admin on Windows)
if (-not $Dir -or $Dir.Trim().Length -eq 0) {
  if ($os -eq 'windows') {
    $Dir = Join-Path $env:USERPROFILE '.local\bin'
  } else {
    if (Test-Path -LiteralPath '/usr/local/bin') {
      try {
        $testPath = Join-Path '/usr/local/bin' '.relampo_write_test'
        New-Item -ItemType File -Path $testPath -Force | Out-Null
        Remove-Item -LiteralPath $testPath -Force
        $Dir = '/usr/local/bin'
      } catch {
        $Dir = Join-Path $HOME '.local/bin'
      }
    } else {
      $Dir = Join-Path $HOME '.local/bin'
    }
  }
}

# Local dir autodetect (like sh script)
if (-not $Local -or $Local.Trim().Length -eq 0) {
  $scriptDir = $null
  if ($MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  }

  if ($scriptDir -and $scriptDir.Trim().Length -gt 0) {
    $candidates = @(
      (Join-Path $scriptDir '..\ops\dist'),
      (Join-Path $scriptDir 'dist')
    )
    foreach ($c in $candidates) {
      try {
        $cResolved = (Resolve-Path -LiteralPath $c).Path
        $localCandidate = Join-Path $cResolved ("relampo_{0}_{1}{2}" -f $os, $arch, $ext)
        if (Test-Path -LiteralPath $localCandidate) {
          $Local = $cResolved
          break
        }
      } catch {
        # ignore
      }
    }
  }
}

# 1) Install from local dir if present
Warn-IfWindowsDefenderNeedsManualSetup -InstallDir $Dir

if ($Local -and $Local.Trim().Length -gt 0) {
  $localBin = Join-Path $Local ("relampo_{0}_{1}{2}" -f $os, $arch, $ext)
  if (Test-Path -LiteralPath $localBin) {
    Install-Bin -SrcPath $localBin -InstallDir $Dir -InstallName $installName
    exit 0
  }
}

# 2) Determine URL for download
# Normalize: allow Version to be provided as vX.Y.Z
if ($Version -and $Version.StartsWith('v')) {
  $tag = $Version
  $Version = $Version.Substring(1)
}

if (-not $Url -or $Url.Trim().Length -eq 0) {
  if (-not $tag -or $tag.Trim().Length -eq 0) {
    if (-not $Version -or $Version.Trim().Length -eq 0) {
      try {
        $latestTxt = (Invoke-WebRequest -Headers @{ 'User-Agent' = 'relampo-installer' } -Uri $latestUrl -UseBasicParsing).Content
        $latestTxt = ($latestTxt -replace '\s', '')
      } catch {
        $latestTxt = $null
      }
      if ($latestTxt -and $latestTxt.Trim().Length -gt 0) {
        $Version = $latestTxt.Trim()
        $tag = "v$Version"
      } else {
        $latest = Invoke-HttpJson -RequestUrl ("https://api.github.com/repos/{0}/releases/latest" -f $Repo)
        $tag = $latest.tag_name
        if (-not $tag -or $tag.Trim().Length -eq 0) {
          throw "Error: unable to detect latest release tag."
        }
        $Version = $tag.TrimStart('v')
      }
    } else {
      # Try v<version> then <version> against releases/tags
      $candidates = @("v$Version", "$Version")
      foreach ($cand in $candidates) {
        $probe = "https://api.github.com/repos/{0}/releases/tags/{1}" -f $Repo, $cand
        if (Test-HttpOk -RequestUrl $probe) {
          $tag = $cand
          break
        }
      }
      if (-not $tag -or $tag.Trim().Length -eq 0) {
        $tag = "v$Version"
      }
    }
  }

  if (-not $Version -or $Version.Trim().Length -eq 0) {
    $Version = $tag.TrimStart('v')
  }

  $archiveName = "relampo_{0}_{1}_{2}.{3}" -f $Version, $os, $arch, $archiveExt

  if ($baseUrl -and $baseUrl.Trim().Length -gt 0) {
    if ($baseUrl.TrimEnd('/') -match '/v[^/]+$') {
      $Url = ($baseUrl.TrimEnd('/') + '/' + $archiveName)
    } else {
      $Url = ($baseUrl.TrimEnd('/') + '/' + $tag + '/' + $archiveName)
    }
  } else {
    $Url = "https://github.com/{0}/releases/download/{1}/{2}" -f $Repo, $tag, $archiveName
  }
}

# 3) Download + extract
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('n'))
Ensure-Dir -Path $tmpDir

try {
  $archivePath = Join-Path $tmpDir ("relampo.{0}" -f $archiveExt)
  try {
    Download-File -RequestUrl $Url -OutFile $archivePath
  } catch {
    throw "Error: failed to download $Url"
  }

  $unpackDir = Join-Path $tmpDir 'unpack'
  Ensure-Dir -Path $unpackDir

  if ($archiveExt -eq 'zip') {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $unpackDir -Force
  } else {
    # tar must be available (on mac/linux it's present; on modern Windows it is too)
    & tar -xzf $archivePath -C $unpackDir
  }

  $binNameInArchive = $installName
  $found = Get-ChildItem -LiteralPath $unpackDir -Recurse -File | Where-Object { $_.Name -ieq $binNameInArchive } | Select-Object -First 1
  if (-not $found) {
    throw "Error: could not find $binNameInArchive in archive."
  }

  Install-Bin -SrcPath $found.FullName -InstallDir $Dir -InstallName $installName
} finally {
  try { Remove-Item -LiteralPath $tmpDir -Recurse -Force } catch { }
}
