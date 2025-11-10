<#
Build-HPLTFS.ps1
Automated build script for HPLTFS on Windows.
Handles MSYS2 setup, WinFsp/FUSE detection from registry, and builds HPLTFS with optional FUSE support.
#>

param(
    [switch] $Install,
    [string] $Prefix = "C:/HPLTFS/install"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- MSYS2 detection ---
$Msys2Root = "C:\msys64"
$Msys2Bash = "$Msys2Root\usr\bin\bash.exe"
if (-not (Test-Path $Msys2Bash)) {
    Write-Error "MSYS2 not found. Please install MSYS2 manually from https://www.msys2.org/ and rerun."
    exit 1
}

# --- Repository root ---
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
Write-Host "Repository root: $RepoRoot"
Write-Host "Install prefix: $Prefix"

# --- Convert Windows path to MSYS2 path ---
$DriveLetter = $RepoRoot.Substring(0,1).ToLower()
$MsysRepoRoot = "/$DriveLetter$($RepoRoot.Substring(2) -replace '\\','/')"
$MsysLtfsRoot = "$MsysRepoRoot/ltfs"

# --- WinFsp development files detection (registry-based) ---
$WinFspInclude = ""
$WinFspLib     = ""
$EnableFuse    = ""

try {
    $regKey = "HKLM:\SOFTWARE\WOW6432Node\WinFsp"
    $installPath = (Get-ItemProperty -Path $regKey -Name "InstallDir").InstallDir
    if (Test-Path $installPath) {
        $WinFspInclude = Join-Path $installPath "inc"
        $WinFspLib     = Join-Path $installPath "lib"
        if ((Test-Path $WinFspInclude) -and (Test-Path $WinFspLib)) {
            Write-Host "WinFsp development files detected at $installPath. Enabling FUSE support."
            $EnableFuse = "--enable-fuse"
        } else {
            Write-Warning "WinFsp headers/libs missing under $installPath. FUSE disabled."
        }
    } else {
        Write-Warning "WinFsp registry entry found but directory does not exist. FUSE disabled."
    }
} catch {
    Write-Warning "WinFsp not found in registry. FUSE support disabled."
}

# --- MSYS2 packages required ---
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
if ($EnableFuse -ne "") { $Deps += "mingw-w64-x86_64-fuse" }

$DepsList = ($Deps -join " ")

# --- Install missing MSYS2 packages ---
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

# Set environment variables for FUSE to bypass pkg-config if enabled
$FuseEnv = ""
if ($EnableFuse -ne "") {
    $FuseEnv = "export FUSE_MODULE_CFLAGS='-I$WinFspInclude'; export FUSE_MODULE_LIBS='-L$WinFspLib -lfuse';"
}

$BuildCommand = @"
source /etc/profile
$FuseEnv
export PATH=/mingw64/bin:`$PATH
cd $MsysLtfsRoot
./configure --prefix=$Prefix CC=gcc CXX=g++ $EnableFuse
make -j$Cores
"@

if ($Install) { $BuildCommand += "`nmake install" }

Write-Host "Starting HPLTFS build inside MSYS2 MinGW64..."
& $Msys2Bash -lc $BuildCommand

if ($LASTEXITCODE -ne 0) {
    Write-Error "HPLTFS build failed inside MSYS2 MinGW64."
    exit 1
}

Write-Host @"
=== HPLTFS build and optional install completed successfully ===
FUSE support is $(if ($EnableFuse) {"enabled"} else {"disabled"}).
"@ -ForegroundColor Green
