@echo off
title PDF Studio - Install
echo.
echo  Installing PDF Studio for %USERNAME% (no administrator rights needed)...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 (
  echo.
  echo  Installation did not finish.
)
echo.
pause
