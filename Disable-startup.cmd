@echo off
cd /d "%~dp0"
start "" /wait "%~dp0WindowsAudio.exe" --disable-startup
pause
