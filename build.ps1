[CmdletBinding()]
param(
    [string]$Icon = 'yt-grab.ico',
    [string]$Output = 'yt-grab.exe',
    [switch]$Run
)

# IMPORTANT: pas de "throw" ni "exit 1" tant qu'on n'a pas pause()
# sinon la fenetre se ferme avant que l'utilisateur lise l'erreur.

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$buildLog = Join-Path $scriptDir 'build.log'
"=== Build started $(Get-Date -Format o) ===" | Set-Content -Path $buildLog -Encoding UTF8

function Log {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    Add-Content -Path $buildLog -Value $Text -Encoding UTF8
}

function Pause-Exit {
    param([int]$Code = 0)
    Write-Host ""
    Write-Host "Appuie sur une touche pour fermer..." -ForegroundColor Yellow
    try { [void][System.Console]::ReadKey($true) } catch { Read-Host "Entree pour fermer" | Out-Null }
    exit $Code
}

trap {
    Log "ERREUR NON GEREE :" 'Red'
    Log ($_ | Out-String) 'Red'
    if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace 'Red' }
    if ($_.Exception) { Log $_.Exception.ToString() 'Red' }
    Log "Voir build.log pour le detail." 'Yellow'
    Pause-Exit 1
}

$source = Join-Path $scriptDir 'yt-grab.ps1'
$iconPath = Join-Path $scriptDir $Icon
$outputPath = Join-Path $scriptDir $Output

Log "Dossier      : $scriptDir"
Log "Source       : $source"
Log "Icone        : $iconPath  (existe: $(Test-Path $iconPath))"
Log "Sortie       : $outputPath"
Log "PowerShell   : $($PSVersionTable.PSVersion)"
Log "OS           : $([System.Environment]::OSVersion.VersionString)"
Log ""

if (-not (Test-Path $source)) {
    Log "Source introuvable : $source" 'Red'
    Pause-Exit 1
}

$content = Get-Content $source -Raw -Encoding UTF8
$version = if ($content -match "(?m)^\s*\`$AppVersion\s*=\s*'([^']+)'") { $Matches[1] } else { '1.0.0' }
$author  = if ($content -match "(?m)^\s*\`$AppAuthor\s*=\s*'([^']+)'")  { $Matches[1] } else { 'n3lio' }
$title   = if ($content -match "(?m)^\s*\`$AppName\s*=\s*'([^']+)'")    { $Matches[1] } else { 'My YouTube Downloader' }

Log "Build $title v$version par $author" 'Cyan'

$module = Get-Module -ListAvailable -Name ps2exe | Select-Object -First 1
if (-not $module) {
    Log "Module ps2exe absent. Installation (CurrentUser)..." 'Yellow'
    try {
        # NuGet provider parfois manquant — on l'installe en silence si besoin.
        $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
            Log "Installation du provider NuGet..." 'Yellow'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        # Trust PSGallery temporairement pour eviter les prompts
        $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        $previousPolicy = if ($gallery) { $gallery.InstallationPolicy } else { 'Untrusted' }
        if ($previousPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
        try {
            Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Log "ps2exe installe." 'Green'
        } finally {
            if ($previousPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy $previousPolicy -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Log "Echec installation ps2exe : $($_.Exception.Message)" 'Red'
        Log "Essaie a la main : Install-Module ps2exe -Scope CurrentUser" 'Yellow'
        Pause-Exit 1
    }
} else {
    Log "ps2exe deja installe : v$($module.Version)" 'Green'
}

try {
    Import-Module ps2exe -ErrorAction Stop
} catch {
    Log "Import-Module ps2exe a echoue : $($_.Exception.Message)" 'Red'
    Pause-Exit 1
}

$buildArgs = @{
    InputFile   = $source
    OutputFile  = $outputPath
    NoConsole   = $true
    Title       = $title
    Description = "$title - YouTube downloader"
    Company     = $author
    Product     = $title
    Version     = $version
    Copyright   = "(c) $author"
    STA         = $true
}
if (Test-Path $iconPath) {
    $buildArgs['IconFile'] = $iconPath
    Log "Icone embarquee : $iconPath" 'Green'
} else {
    Log "Icone absente, build sans icone." 'Yellow'
}

Log "Compilation en cours..." 'Cyan'
try {
    Invoke-PS2EXE @buildArgs
} catch {
    Log "PS2EXE a echoue : $($_.Exception.Message)" 'Red'
    Pause-Exit 1
}

if (-not (Test-Path $outputPath)) {
    Log "Build termine sans erreur visible mais $outputPath n'existe pas." 'Red'
    Pause-Exit 1
}

$size = [math]::Round((Get-Item $outputPath).Length / 1KB, 1)
Log ""
Log "OK : $outputPath ($size KB)" 'Green'
Log "Tu peux double-cliquer $Output ou l'epingler a la barre des taches." 'Gray'

if ($Run) {
    Log "Lancement de l'exe..." 'Cyan'
    Start-Process $outputPath
}

Pause-Exit 0
