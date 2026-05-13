@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0yt-grab.ps1"
if errorlevel 1 (
    echo.
    echo Le script a quitte avec une erreur. Voir yt-grab-crash.log a cote du script.
    pause
)
