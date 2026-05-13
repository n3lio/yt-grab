[CmdletBinding()]
param(
    [string]$Icon = 'yt-grab.ico',
    [string]$Output = 'yt-grab.exe',
    [switch]$Run
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$source = Join-Path $scriptDir 'yt-grab.ps1'
$iconPath = Join-Path $scriptDir $Icon
$outputPath = Join-Path $scriptDir $Output

if (-not (Test-Path $source)) {
    Write-Error "Source introuvable : $source"
    exit 1
}

# Récupère version + auteur depuis yt-grab.ps1 pour ne pas se désynchroniser
$content = Get-Content $source -Raw -Encoding UTF8
$version = if ($content -match "(?m)^\s*\`$AppVersion\s*=\s*'([^']+)'") { $Matches[1] } else { '1.0.0' }
$author  = if ($content -match "(?m)^\s*\`$AppAuthor\s*=\s*'([^']+)'")  { $Matches[1] } else { 'n3lio' }
$title   = if ($content -match "(?m)^\s*\`$AppName\s*=\s*'([^']+)'")    { $Matches[1] } else { 'My YouTube Downloader' }

Write-Host "Build $title v$version par $author" -ForegroundColor Cyan

# Install ps2exe si absent
$module = Get-Module -ListAvailable -Name ps2exe | Select-Object -First 1
if (-not $module) {
    Write-Host "Installation du module ps2exe (CurrentUser)..." -ForegroundColor Yellow
    try {
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    } catch {
        Write-Error "Echec installation ps2exe : $($_.Exception.Message)"
        Write-Host "Essaie manuellement : Install-Module ps2exe -Scope CurrentUser" -ForegroundColor Yellow
        exit 1
    }
}
Import-Module ps2exe -ErrorAction Stop

$buildArgs = @{
    InputFile   = $source
    OutputFile  = $outputPath
    NoConsole   = $true
    Title       = $title
    Description = "$title — YouTube downloader"
    Company     = $author
    Product     = $title
    Version     = $version
    Copyright   = "(c) $author"
    STA         = $true
}
if (Test-Path $iconPath) {
    $buildArgs['IconFile'] = $iconPath
    Write-Host "Icone : $iconPath" -ForegroundColor Green
} else {
    Write-Host "Pas d'icone trouvee a '$iconPath' — build sans icone." -ForegroundColor Yellow
}

Write-Host "Compilation..." -ForegroundColor Cyan
Invoke-PS2EXE @buildArgs

if (-not (Test-Path $outputPath)) {
    Write-Error "Build echoue : $outputPath introuvable apres compilation."
    exit 1
}

$size = [math]::Round((Get-Item $outputPath).Length / 1KB, 1)
Write-Host ""
Write-Host "OK : $outputPath ($size KB)" -ForegroundColor Green
Write-Host ""
Write-Host "Tu peux maintenant double-cliquer $Output ou l'epingler a la barre des taches." -ForegroundColor Gray

if ($Run) {
    Write-Host "Lancement..." -ForegroundColor Cyan
    Start-Process $outputPath
}
