install visual studio latest (2022 right now)
Install winfsp, include development parts

put uuid.pc into C:\msys64\mingw64\lib\pkgconfig\uuid.pc

# Build only
powershell -ExecutionPolicy Bypass -File .\Build-HPLTFS-OneClick.ps1

# Build and install
powershell -ExecutionPolicy Bypass -File .\Build-HPLTFS-OneClick.ps1 -Install -Prefix "C:/HPLTFS/install"
