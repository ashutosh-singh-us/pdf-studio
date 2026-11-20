@echo off
title PDF Studio - Uninstall
cd /d "%TEMP%"
echo Removing PDF Studio for %USERNAME%...
powershell -NoProfile -Command "Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Programs')) 'PDF Studio.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PDF Studio.lnk')"
rem Delete the install folder last (this script may be running from inside it).
start "" /b cmd /c "timeout /t 1 >nul & rmdir /s /q "%LOCALAPPDATA%\PDF Studio""
echo PDF Studio has been removed.
pause
