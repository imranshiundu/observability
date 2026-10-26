@echo off
rem i-love-shopping observability demo - Windows launcher (Git Bash required)
where bash >nul 2>nul
if %errorlevel% neq 0 (
  echo Git Bash is required. Install from https://git-scm.com/download/win
  pause
  exit /b 1
)
bash "%~dp0start.sh" %*
