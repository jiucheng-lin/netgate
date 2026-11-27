@echo off
chcp 65001 >nul
title NetGate
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
echo Starting NetGate...
echo Local only: http://127.0.0.1:8765
echo Keep this window open. Press Ctrl+C to stop.
start "" http://127.0.0.1:8765
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -Port 8765
pause
