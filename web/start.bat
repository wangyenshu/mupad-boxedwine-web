@echo off
rem MuPAD Light 2.5 launcher for Boxedwine (installed next to MupLight.exe).
cd /d "%~dp0"

rem Boxedwine's file system skips wineboot, so nothing starts the service manager.
rem MuPAD reaches VCam Light (plots) and the help programs over out-of-process COM,
rem which needs Wine's RPC service (rpcss), which COM starts through the service manager.
start services.exe

rem The first start does what the installer's custom actions do: each program
rem registers its OLE automation server (/regserver). The marker file and Wine's
rem registry live in Boxedwine's writable layer, kept in the browser's IndexedDB.
set MARKER=%APPDATA%\SciFace\boxedwine-registered.txt
if exist "%MARKER%" goto run
echo Registering MuPAD Light...
start /wait lhlpbrowse.exe /regserver
start /wait VCamLght.exe /regserver
start /wait muplhelp.exe /regserver
start /wait MupLight.exe /regserver
if not exist "%APPDATA%\SciFace" mkdir "%APPDATA%\SciFace"
echo MuPAD Light 2.5 registered> "%MARKER%"
:run
start /wait MupLight.exe %*
