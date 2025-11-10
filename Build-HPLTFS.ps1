<#
Build-HPLTFS-Auto-NoFUSE.ps1
Fully automated HPLTFS build on Windows (FUSE disabled)
Installs only missing MSYS2 packages
#>

param(
    [switch] $Install,
    [string] $Prefix = "C:/HPLTFS/install"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Function to get latest MSYS2 installer ---
function Get-LatestMsys2InstallerUrl {
    $baseUrl = "https://repo.msys2.org/distrib/x86_64/"
    $html = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing
    $match = ($html.Links | Where-Object { $_.href -match "^msys2-x86_64-\d{8}\.exe$" } | Sort-Object href)[-1]
    if (-not $match) { throw "Could not find latest MSYS2 installer." }
    return $baseUrl + $match.href
}

# --- MSYS2 detection ---
$Msys2Root = "C:\msys64"
$Msys2Bash = "$Msys2Root\usr\bin\bash.exe"

if (-not (Test-Path $Msys2Bash)) {
    Write-Host "MSYS2 not found. Downloading..."
    $InstallerUrl = Get-LatestMsys2InstallerUrl
    $InstallerPath = "$env:TEMP\msys2-installer.exe"
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath
    Start-Process -FilePath $InstallerPath -Wait
}

if (-not (Test-Path $Msys2Bash)) {
    Write-Error "MSYS2 bash not found after installation."
    exit 1
}

Write-Host "MSYS2 bash detected at $Msys2Bash"

# --- Repository root ---
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
Write-Host "Repository root: $RepoRoot"
Write-Host "Install prefix: $Prefix"

# --- Convert Windows path to MSYS2 path ---
$DriveLetter = $RepoRoot.Substring(0,1).ToLower()
$MsysRepoRoot = "/$DriveLetter$($RepoRoot.Substring(2) -replace '\\','/')"
$MsysLtfsRoot = "$MsysRepoRoot/ltfs"

# --- MSYS2 packages ---
$Deps = @(
    "base-devel",
    "mingw-w64-x86_64-toolchain",
    "git",
    "curl",
    "mingw-w64-x86_64-libxml2",
    "mingw-w64-x86_64-icu",
    "mingw-w64-x86_64-zlib",
    "mingw-w64-x86_64-libtool"
)

# --- Build space-separated list for Bash ---
$DepsList = ($Deps -join " ")

# --- Install missing MSYS2 packages (protected $pkg) ---
$PkgInstallCommand = '
source /etc/profile
for pkg in ' + $DepsList + '; do
    if ! pacman -Q "$pkg" >/dev/null 2>&1; then
        echo Installing missing package: $pkg
        pacman -S --noconfirm "$pkg"
    else
        echo Package $pkg already installed, skipping
    fi
done
'

Write-Host "Installing missing MSYS2 packages..."
& $Msys2Bash -lc $PkgInstallCommand

# --- Check configure script exists ---
if (-not (Test-Path "$RepoRoot\ltfs\configure")) {
    Write-Error "No configure script found in ltfs folder. Cannot build."
    exit 1
}

# --- Build HPLTFS ---
$Cores = [Environment]::ProcessorCount

$BuildCommand = '
source /etc/profile
export PATH=/mingw64/bin:$PATH
cd ' + $MsysLtfsRoot + '
./configure --prefix=' + $Prefix + ' CC=gcc CXX=g++ --disable-fuse
make -j' + $Cores

if ($Install) {
    $BuildCommand += "`nmake install"
}

Write-Host "Starting HPLTFS build inside MSYS2 MinGW64 (FUSE disabled)..."
& $Msys2Bash -lc $BuildCommand

if ($LASTEXITCODE -ne 0) {
    Write-Error "HPLTFS build failed inside MSYS2 MinGW64."
    exit 1
}

Write-Host "=== HPLTFS build and optional install completed successfully ===" -ForegroundColor Green
Write-Host "Note: FUSE support is disabled. To enable FUSE, install WinFsp: https://winfsp.dev/"
