@echo off
rem Build rio_udp_rx.exe and disk_bench.exe with MSVC (x64). Adjust VCVARS if Visual Studio is elsewhere.
setlocal
if not defined VCVARS set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
call "%VCVARS%" >nul || exit /b 1
cd /d "%~dp0"
cl /nologo /O2 /EHsc /W4 /std:c++17 /utf-8 rio_udp_rx.cpp /Fe:rio_udp_rx.exe /link ws2_32.lib || exit /b 1
cl /nologo /O2 /EHsc /W4 /std:c++17 /utf-8 disk_bench.cpp /Fe:disk_bench.exe || exit /b 1
