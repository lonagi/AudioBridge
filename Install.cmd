@echo off
cd /d "%~dp0"
echo Installing AudioBridge for the current Windows user...
start "" /wait "%~dp0WindowsAudio.exe" --install
if errorlevel 1 (
  echo Installation failed. Please check the message above.
) else (
  echo AudioBridge is ready. Manage startup in Task Manager - Startup apps.
)
pause
