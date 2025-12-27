<#
Build-HPLTFS.ps1
Build HPLTFS inside MSYS2 MinGW64 on Windows.
Usage:
  powershell -ExecutionPolicy Bypass -File .\Build-HPLTFS.ps1
  powershell -ExecutionPolicy Bypass -File .\Build-HPLTFS.ps1 -Install

This script forces MSYSTEM=MINGW64 (so /mingw64/bin/gcc is used).
#>

param(
    [switch] $Install,
    [string] $Prefix = "C:/HPLTFS/install"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------
# Config / detection
# ---------------------------
$RepoRoot = (Resolve-Path .\ | Select-Object -ExpandProperty Path)
$Msys2Root = "C:\msys64"
$BashExe = Join-Path $Msys2Root "usr\bin\bash.exe"

if (-not (Test-Path $BashExe)) {
    Write-Error "MSYS2 bash not found at $BashExe. Install MSYS2 from https://www.msys2.org/ and retry."
    exit 1
}

Write-Host "Repo root: $RepoRoot"
Write-Host "MSYS2 root: $Msys2Root"
Write-Host "Using bash: $BashExe"

# Escape Windows path -> MSYS2 path with shell-escaping for spaces and parens
function Escape-Msys2Path($winPath) {
    if ([string]::IsNullOrEmpty($winPath)) { return "" }
    # Normalize separators and drive letter
    $p = $winPath -replace '\\','/'
    $p = $p -replace '^([A-Za-z]):', '/$1'
    # Escape spaces and parentheses for shell
    $p = $p -replace ' ', '\ '
    $p = $p -replace '\(', '\\('
    $p = $p -replace '\)', '\\)'
    return $p
}

$MsysRepoRoot = Escape-Msys2Path $RepoRoot
$MsysLtfsRoot = "$MsysRepoRoot/ltfs"
$MsysPrefix   = Escape-Msys2Path $Prefix
$MsysPkgConfigDir = Escape-Msys2Path (Join-Path $Msys2Root "mingw64\lib\pkgconfig")

# ---------------------------
# WinFsp detection (registry + common locations)
# ---------------------------
$WinFspInc = $null
$WinFspLib = $null
$EnableFuse = $false

# Check registry first (WOW6432Node)
try {
    $regKey = "HKLM:\SOFTWARE\WOW6432Node\WinFsp"
    if (Test-Path $regKey) {
        $installPath = (Get-ItemProperty -Path $regKey -Name "InstallDir" -ErrorAction SilentlyContinue).InstallDir
        if ($installPath -and (Test-Path $installPath)) {
            $candidateInc = Join-Path $installPath "inc"
            $candidateLib = Join-Path $installPath "lib"
            if ((Test-Path $candidateInc) -and (Test-Path $candidateLib)) {
                $WinFspInc = $candidateInc
                $WinFspLib = $candidateLib
                $EnableFuse = $true
            }
        }
    }
} catch { }

# If not found, try common folders
if (-not $EnableFuse) {
    $candidates = @(
        "C:\Program Files (x86)\WinFsp",
        "C:\Program Files\WinFsp",
        "C:\WinFsp"
    )
    foreach ($root in $candidates) {
        if (Test-Path $root) {
            $candidateInc = Join-Path $root "inc"
            $candidateLib = Join-Path $root "lib"
            $candidateLib2 = Join-Path $root "x64"
            if ((Test-Path $candidateInc) -and (Test-Path $candidateLib)) {
                $WinFspInc = $candidateInc; $WinFspLib = $candidateLib; $EnableFuse = $true; break
            } elseif ((Test-Path $candidateInc) -and (Test-Path $candidateLib2)) {
                $WinFspInc = $candidateInc; $WinFspLib = $candidateLib2; $EnableFuse = $true; break
            }
        }
    }
}

if ($EnableFuse) {
    Write-Host "WinFsp dev files found:"
    Write-Host "  inc: $WinFspInc"
    Write-Host "  lib: $WinFspLib"
} else {
    Write-Warning "WinFsp development files not found. FUSE will be disabled for the build."
}

# Convert WinFsp to MSYS escaped paths
$MsysWinFspInc = Escape-Msys2Path $WinFspInc
$MsysWinFspLib = Escape-Msys2Path $WinFspLib

# ---------------------------
# Required MSYS2 packages (only those that exist in MSYS2)
# ---------------------------
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
$DepsList = $Deps -join " "

# ---------------------------
# Helper to run commands inside MSYS2 MinGW64
# We must set MSYSTEM=MINGW64 BEFORE starting bash; do that via cmd.exe /c "set VAR=... && bash -lc '...'"
# ---------------------------
function Invoke-InMsys {
    param($msysScript)  # multiline string of shell commands
    # Replace Windows CRLF with semicolons (so we can run as one-liner)
    $oneLine = $msysScript -replace "`r?`n","; "
    # Build cmd line: set vars then call bash -lc "commands"
    $cmdLine = "set MSYSTEM=MINGW64&& set CHERE_INVOKING=1&& `"$BashExe`" -lc `"$oneLine`""
    # Run via cmd.exe to ensure MSYSTEM is set before bash starts
    & cmd.exe /c $cmdLine
    $exit = $LASTEXITCODE
    return $exit
}

# ---------------------------
# Install missing MSYS2 packages (idempotent)
# ---------------------------
Write-Host "Installing missing MSYS2 packages (only if missing)..."
# ----------------------------
# MSYS2 dependency installation script
# ----------------------------
$PkgScript = @'
DepsList="autoconf automake libtool make pkgconf libxml2 icu"

for pkg in $DepsList; do
    if ! pacman -Q "$pkg" >/dev/null 2>&1; then
        echo "Installing missing package: $pkg"
        pacman -S --noconfirm "$pkg"
    else
        echo "Package already installed: $pkg"
    fi
done
'@


$rc = Invoke-InMsys $pkgScript
if ($rc -ne 0) { Write-Error "pacman failed (exit $rc). Run MSYS2 and update pacman first."; exit 1 }

# ---------------------------
# Ensure ltfs configure exists
# ---------------------------
if (-not (Test-Path (Join-Path $RepoRoot "ltfs\configure"))) {
    Write-Error "No configure script found in ltfs folder. Run autogen/autoreconf inside MSYS2 mingw64 shell if needed."
    exit 1
}

# ---------------------------
# Create fake uuid.pc for Windows so pkg-config 'uuid' exists and points to rpcrt4
# Use single-quoted here-string so PowerShell doesn't expand $variables inside.
# ---------------------------
$pkgConfigWindowsPath = Join-Path $Msys2Root "mingw64\lib\pkgconfig"
if (-not (Test-Path $pkgConfigWindowsPath)) { New-Item -ItemType Directory -Force -Path $pkgConfigWindowsPath | Out-Null }

$uuidPc = @'
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

$uuidPcPath = Join-Path $pkgConfigWindowsPath "uuid.pc"
Set-Content -Path $uuidPcPath -Value $uuidPc -Encoding ASCII
Write-Host "Wrote fake pkg-config file: $uuidPcPath"

# ---------------------------
# Build command (inside MinGW64)
# ---------------------------
$Cores = [Environment]::ProcessorCount
# Build environment flags for FUSE if present
$FuseExport = ""
if ($EnableFuse) {
    $FuseExport = "export FUSE_MODULE_CFLAGS='-I$MsysWinFspInc'; export FUSE_MODULE_LIBS='-L$MsysWinFspLib -lfuse';"
}

# Ensure PKG_CONFIG_PATH includes our fake uuid.pc
$MsysPkgConfigDirEsc = Escape-Msys2Path "$Msys2Root\mingw64\lib\pkgconfig"
$MsysMessagesDirEsc = Escape-Msys2Path (Join-Path $RepoRoot "ltfs\messages")

$buildScript = @"
# enter profile and env
source /etc/profile
$FuseExport
export PKG_CONFIG_PATH=${MsysPkgConfigDirEsc}:\${PKG_CONFIG_PATH}
export GENRB='genrb -O $MsysMessagesDirEsc'
cd $MsysLtfsRoot
./configure --prefix=$MsysPrefix CC=gcc CXX=g++ $([string]::Join(' ', (if ($EnableFuse) { '--enable-fuse'} else {''}))) CFLAGS='-I$MsysWinFspInc' LDFLAGS='-L$MsysWinFspLib'
make -j$Cores
"@

Write-Host "Starting build inside MSYS2 MinGW64 (this may take several minutes)..."
$rc = Invoke-InMsys $buildScript
if ($rc -ne 0) {
    Write-Error "Build failed inside MSYS2 (exit $rc). Inspect MSYS2 console output above for the failing step."
    exit 1
}

if ($Install) {
    $installScript = @"
source /etc/profile
cd $MsysLtfsRoot
make install
"@
    Invoke-InMsys $installScript
}

# Final summary
Write-Host "=======================================" -ForegroundColor Green
Write-Host "HPLTFS build completed successfully." -ForegroundColor Green
Write-Host "Install prefix (MSYS style): $MsysPrefix"
Write-Host "FUSE support: $($EnableFuse -eq $true)"
Write-Host "ICU messages directory: $MsysMessagesDirEsc"
Write-Host "=======================================" -ForegroundColor Green

exit 0
