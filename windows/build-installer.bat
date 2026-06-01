@echo off
setlocal

echo ============================================
echo  yt-grab — Build complet : EXE + Installer
echo ============================================
echo.

:: 1. Compiler le PS1 en EXE
echo [1/2] Compilation du .exe...
call build.bat
if not exist "yt-grab.exe" (
    echo ERREUR : yt-grab.exe introuvable apres la compilation.
    pause
    exit /b 1
)

echo.
echo [2/2] Generation de l'installer avec Inno Setup...
echo.

:: Cherche Inno Setup dans les emplacements habituels
set ISCC=
if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set ISCC="%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe"       set ISCC="%ProgramFiles%\Inno Setup 6\ISCC.exe"
if exist "%LocalAppData%\Programs\Inno Setup 6\ISCC.exe" set ISCC="%LocalAppData%\Programs\Inno Setup 6\ISCC.exe"

if "%ISCC%"=="" (
    echo Inno Setup introuvable.
    echo Telecharge-le sur https://jrsoftware.org/isinfo.php puis relance ce script.
    pause
    exit /b 1
)

%ISCC% installer.iss
if errorlevel 1 (
    echo ERREUR : Inno Setup a echoue. Voir les logs ci-dessus.
    pause
    exit /b 1
)

echo.
echo ============================================
echo  OK ! Installer genere dans : dist\
echo ============================================
echo.
if exist "dist\yt-grab-*.exe" (
    for %%f in (dist\yt-grab-*-setup.exe) do echo  -^> %%f
)
echo.
pause
