<#
Build-HPLTFS.ps1
Automated build script for HPLTFS on Windows.
Handles MSYS2 setup, WinFsp/FUSE detection, UUID support, ICU GENRB, and builds HPLTFS.
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

# --- Convert Windows path to MSYS2 path and escape spaces/parentheses ---
function Convert-ToMsys2Path($winPath) {
    $msys = $winPath -replace '^([A-Za-z]):', '/$1' -replace '\\','/'
    $msys = $msys -replace ' ', '\\ ' -replace '\(', '\\(' -replace '\)', '\\)'
    return $msys
}
$MsysRepoRoot = Convert-ToMsys2Path $RepoRoot
$MsysLtfsRoot = "$MsysRepoRoot/ltfs"
$MsysPrefix = Convert-ToMsys2Path $Prefix

# --- WinFsp detection ---
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

# Convert WinFsp paths to MSYS2 paths
$MsysWinFspInclude = Convert-ToMsys2Path $WinFspInclude
$MsysWinFspLib     = Convert-ToMsys2Path $WinFspLib

# --- Required MSYS2 packages ---
$Deps = @(
    "base-devel",
    "mingw-w64-x86_64-toolchain",
    "git",
    "curl",
    "mingw-w64-x86_64-libxml2",
    "mingw-w64-x86_64-icu",
    "mingw-w64-x86_64-zlib",
    "mingw-w64-x86_64-libtool",
    "autoconf",
    "automake",
    "pkg-config"
)
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

# --- Ensure ltfs folder exists ---
if (-not (Test-Path "$RepoRoot\ltfs\configure")) {
    Write-Error "No configure script found in ltfs folder. Cannot build."
    exit 1
}

# Create fake uuid.pc for Windows
$PkgConfigDir = "$Msys2Root\mingw64/lib/pkgconfig"
if (-not (Test-Path $PkgConfigDir)) { New-Item -ItemType Directory -Force -Path $PkgConfigDir | Out-Null }
$UuidPc = @'
prefix=/mingw64
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: uuid
Description: UUID library
Version: 1.36
Libs: -lrpcrt4
Cflags: -I${includedir}
'@

$UuidPcPath = Join-Path $PkgConfigDir "uuid.pc"
Set-Content -Path $UuidPcPath -Value $UuidPc
Write-Host "Created fake uuid.pc for pkg-config at $UuidPcPath"


# --- Build HPLTFS ---
$Cores = [Environment]::ProcessorCount

# FUSE environment if enabled
$FuseEnv = ""
if ($EnableFuse -ne "") {
    $FuseEnv = "export FUSE_MODULE_CFLAGS='-I$MsysWinFspInclude'; export FUSE_MODULE_LIBS='-L$MsysWinFspLib -lfuse';"
}

# GENRB fix for ICU messages
$BuildCommand = @"
source /etc/profile
export PKG_CONFIG_PATH=$PkgConfigDir
$FuseEnv
export GENRB='genrb -O $MsysLtfsRoot/messages'
cd $MsysLtfsRoot
./configure --prefix=$MsysPrefix CC=gcc CXX=g++ $EnableFuse
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
UUID support uses Windows rpcrt4 library.
"@ -ForegroundColor Green
