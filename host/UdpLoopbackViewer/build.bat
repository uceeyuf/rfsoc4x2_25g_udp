@echo off
rem Build loopback_io.dll (packet engine, MSVC x64) and UdpLoopbackViewer.exe (WinForms,
rem .NET Framework 4.8 - included with Windows 10/11). Set VCVARS / CSC if Visual Studio is elsewhere.
setlocal
if not defined VCVARS set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
if not defined CSC set "CSC=C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\Roslyn\csc.exe"
set "FW=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319"
cd /d "%~dp0"
call "%VCVARS%" >nul || exit /b 1
cl /nologo /O2 /EHsc /W4 /std:c++17 /LD loopback_io.cpp /Fe:loopback_io.dll /link ws2_32.lib || exit /b 1
"%CSC%" /nologo /target:winexe /platform:x64 /optimize+ /langversion:7.3 /out:UdpLoopbackViewer.exe ^
  /r:"%FW%\System.dll" /r:"%FW%\System.Drawing.dll" /r:"%FW%\System.Windows.Forms.dll" ^
  Program.cs || exit /b 1
