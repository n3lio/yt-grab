@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0build.ps1" %*
echo.
echo Le build est termine. Voir build.log a cote du script.
pause
