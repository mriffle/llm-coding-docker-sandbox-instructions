@echo off
rem Shim so `claude-sandbox` works from cmd.exe and never trips execution policy.
rem Installed by the agent-sandbox installer (v@@VERSION@@).
setlocal
set "SANDBOX_PS1=%~dp0claude-sandbox.ps1"
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%SANDBOX_PS1%" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SANDBOX_PS1%" %*
)
exit /b %ERRORLEVEL%
