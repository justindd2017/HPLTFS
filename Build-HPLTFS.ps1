<#
Build-HPLTFS.ps1
Windows build script for HPLTFS using CMake + vcpkg + Visual Studio.

Usage:
  .\Build-HPLTFS.ps1 [-Install] [-Configuration Release|Debug] [-Prefix "C:\InstallDir"]
Example:
  .\Build-HPLTFS.ps1 -Install -Configuration Release -Prefix "C:\HPLTFS"
#>

param(
    [switch] $Install,
    [string] $Prefix = "C:\Program Files\HPLTFS",
    [ValidateSet("Debug","Release")]
    [string] $Configuration = "Release",
    [string] $VcpkgDir,
    [string] $Triplet = "x64-windows",
    [int] $Jobs = 0  # 0 = auto
)

# --- Initialize defaults that depend on script location ---
if (-not $VcpkgDir) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $VcpkgDir   = Join-Path $ScriptRoot "vcpkg"
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== HPLTFS Windows Build Script ===" -ForegroundColor Cyan
Write-Host "Install: $Install"
Write-Host "Prefix: $Prefix"
Write-Host "Configuration: $Configuration"
Write-Host "Vcpkg dir: $VcpkgDir"
Write-Host "Triplet: $Triplet"
Write-Host ""

# --- Verify dependencies ---
if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue)) {
    Write-Error "CMake not found. Please install CMake and ensure it’s in PATH."
    exit 1
}
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    Write-Error "MSVC compiler not found. Run this from a 'Developer Command Prompt for VS 2022'."
    exit 1
}

# --- Clone and bootstrap vcpkg if missing ---
if (!(Test-Path $VcpkgDir)) {
    Write-Host "Cloning vcpkg..."
    git clone https://github.com/microsoft/vcpkg.git $VcpkgDir
}
Push-Location $VcpkgDir
if (!(Test-Path (Join-Path $VcpkgDir "vcpkg.exe"))) {
    Write-Host "Bootstrapping vcpkg..."
    .\bootstrap-vcpkg.bat
}
Pop-Location

# --- Install dependencies via vcpkg ---
Write-Host "Installing dependencies via vcpkg..."
$Deps = @("libxml2", "zlib", "icu", "fuse3")
foreach ($dep in $Deps) {
    Write-Host "Installing $dep..."
    & "$VcpkgDir\vcpkg.exe" install "${dep}:${Triplet}"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install dependency: $dep"
        exit 1
    }
}

# --- Set up build directories ---
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BuildDir = Join-Path $RepoRoot "build_windows"
if (!(Test-Path $BuildDir)) {
    New-Item -ItemType Directory -Path $BuildDir | Out-Null
}
Set-Location $BuildDir

# --- Run CMake configure ---
Write-Host "Running CMake configure..."
$Toolchain = Join-Path $VcpkgDir "scripts\buildsystems\vcpkg.cmake"
$Generator = "Visual Studio 17 2022"

& cmake -G $Generator -A x64 `
    -DCMAKE_BUILD_TYPE=$Configuration `
    -DCMAKE_TOOLCHAIN_FILE="$Toolchain" `
    -DCMAKE_INSTALL_PREFIX="$Prefix" `
    "$RepoRoot"

if ($LASTEXITCODE -ne 0) {
    Write-Error "CMake configure failed."
    exit 1
}

# --- Build ---
Write-Host "Building HPLTFS..."
$BuildArgs = @("--config", $Configuration)
if ($Jobs -gt 0) {
    $BuildArgs += @("--", "/m:$Jobs")
} else {
    $BuildArgs += @("--", "/m")
}

& cmake --build . @BuildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed."
    exit 1
}

# --- Optional install ---
if ($Install) {
    Write-Host "Installing to $Prefix..."
    & cmake --install . --config $Configuration
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Install failed."
        exit 1
    }
}

Write-Host "=== HPLTFS build completed successfully ===" -ForegroundColor Green
