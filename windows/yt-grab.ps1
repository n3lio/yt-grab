[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ================================================================
#  App metadata
# ================================================================
$AppName    = 'YouTube Grabber by n3lio'
$AppVersion = '2.3.0'
$AppAuthor  = 'n3lio'
$AppRepo    = 'https://github.com/n3lio/yt-grab'

# Constantes de config (centralisées pour éviter les magic numbers dispersés)
$AppConfig = @{
    HistoryMax          = 10       # Nombre max d'URLs dans l'historique
    FilenameMax         = 200      # Longueur max d'un nom de fichier (chars)
    TimerMs             = 200      # Intervalle du timer principal (ms)
    ToastMs             = 4000     # Durée du toast "download completed" (ms)
    ToastDisposeMs      = 5000     # Délai avant Dispose du NotifyIcon (ms)
    TitleTruncateChars  = 45       # Troncature du titre dans le statut bar
    QueueSaveDebounceMs = 1000     # Throttle Save-QueueToConfig (ms)
    PreviewDebounceMs   = 400      # Debounce du preview job après TextChanged (ms)
    NetTimeoutSec       = 20       # Timeout des appels API GitHub
    DlTimeoutSec        = 120      # Timeout des DL yt-dlp/setup (s)
    FfmpegDlTimeoutSec  = 300      # Timeout du DL ffmpeg (zip lourd) (s)
}

# scriptDir — robuste en mode exe PS2EXE (localisation de l'exe uniquement, en lecture)
$scriptDir = $null
try { if ($MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } } catch {}
if (-not $scriptDir) { try { $scriptDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {} }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

# dataDir — dossier persistant (config + tools téléchargés + logs)
# On sort de Program Files (qui exige des droits admin en écriture) pour aller dans LOCALAPPDATA
$dataDir = $null
try {
    $lad = $env:LOCALAPPDATA
    if (-not $lad) { $lad = [Environment]::GetFolderPath('LocalApplicationData') }
    if ($lad) { $dataDir = Join-Path $lad 'YouTubeGrabber' }
} catch {}
if (-not $dataDir) { $dataDir = $scriptDir }
if (-not (Test-Path $dataDir)) { try { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null } catch {} }

$crashLog   = Join-Path $dataDir 'ytgrabber-crash.log'
$configFile = Join-Path $dataDir 'ytgrabber.config.json'

# Migration : si un ancien fichier config existe à côté de l'exe (installations pré-v2.3.0),
# on le déplace vers dataDir au premier lancement
try {
    $legacyConfig = Join-Path $scriptDir 'ytgrabber.config.json'
    if ((Test-Path $legacyConfig) -and -not (Test-Path $configFile) -and ($legacyConfig -ne $configFile)) {
        Move-Item -Path $legacyConfig -Destination $configFile -Force -ErrorAction SilentlyContinue
    }
    $legacyCrash = Join-Path $scriptDir 'ytgrabber-crash.log'
    if ((Test-Path $legacyCrash) -and -not (Test-Path $crashLog) -and ($legacyCrash -ne $crashLog)) {
        Move-Item -Path $legacyCrash -Destination $crashLog -Force -ErrorAction SilentlyContinue
    }
    # Legacy version log : on ne le migre pas — il sera supprimé par Cleanup-LegacyFiles (utile pour rien)
    $legacyVer = Join-Path $scriptDir 'ytgrabber-version.log'
    if (Test-Path $legacyVer) { Remove-Item $legacyVer -Force -ErrorAction SilentlyContinue }
} catch {}

# ================================================================
#  Crash log
# ================================================================
function Write-Crash {
    param([string]$Where, $ErrObj)
    try {
        $msg = "[$(Get-Date -Format o)] $Where`n"
        if ($ErrObj) {
            $msg += ($ErrObj | Out-String)
            if ($ErrObj.ScriptStackTrace) { $msg += "`n$($ErrObj.ScriptStackTrace)`n" }
            if ($ErrObj.Exception)        { $msg += "`n$($ErrObj.Exception.ToString())`n" }
        }
        $msg += "`n----`n"
        Add-Content -Path $crashLog -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

# ================================================================
#  Config JSON
# ================================================================
function Read-Config {
    if (Test-Path $configFile) {
        try { return Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    return [PSCustomObject]@{}
}

function Save-Config {
    param($Cfg)
    try { $Cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding UTF8 } catch {}
}

function Get-CfgProp {
    param($Cfg, [string]$Name, $Default = $null)
    if ($Cfg -and ($Cfg.PSObject.Properties.Name -contains $Name) -and $null -ne $Cfg.$Name) { return $Cfg.$Name }
    return $Default
}

function Set-CfgProp {
    param($Cfg, [string]$Name, $Value)
    if ($Cfg.PSObject.Properties.Name -contains $Name) { $Cfg.$Name = $Value }
    else { $Cfg | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# ================================================================
#  Ensure-Tool : trouve ou télécharge yt-dlp / ffmpeg
# ================================================================
function Ensure-Tool {
    param([string]$Name, [string]$ExeName)
    $cfg = Read-Config
    $saved = Get-CfgProp $cfg $Name
    if ($saved -and (Test-Path $saved)) { return $saved }

    # 1. Cherche à côté de l'exe (installations qui bundlent yt-dlp / ffmpeg)
    $inApp = Join-Path $scriptDir $ExeName
    if (Test-Path $inApp) { return $inApp }

    # 2. Cherche dans le dossier data (installations précédentes < v2.3.0 ont pu télécharger ici après migration)
    $inData = Join-Path $dataDir $ExeName
    if (Test-Path $inData) { return $inData }

    # 3. PATH système
    $sys = Get-Command $Name -ErrorAction SilentlyContinue
    if ($sys) { return $sys.Source }

    # 4. Emplacements user classiques
    foreach ($root in @(
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Downloads\yt-dlp'),
        (Join-Path $env:USERPROFILE 'Downloads\ffmpeg\bin'),
        'C:\ffmpeg\bin', 'C:\Program Files\ffmpeg\bin')) {
        $c = Join-Path $root $ExeName
        if (Test-Path $c) {
            Set-CfgProp $cfg $Name $c; Save-Config $cfg
            return $c
        }
    }

    # 5. Téléchargement automatique — DANS dataDir (écriture garantie sans droits admin)
    $dest = Join-Path $dataDir $ExeName
    $ok   = $false
    try {
        if ($Name -eq 'yt-dlp') {
            $rel   = Invoke-RestMethod 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -UseBasicParsing -TimeoutSec 20
            $asset = $rel.assets | Where-Object { $_.name -eq 'yt-dlp.exe' } | Select-Object -First 1
            Invoke-WebRequest $asset.browser_download_url -OutFile $dest -UseBasicParsing -TimeoutSec 120
            $ok = $true
        } elseif ($Name -eq 'ffmpeg') {
            $zip = Join-Path $env:TEMP 'ffmpeg-dl.zip'
            $ext = Join-Path $env:TEMP 'ffmpeg-ext'
            Invoke-WebRequest 'https://github.com/GyanD/codexffmpeg/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip' -OutFile $zip -UseBasicParsing -TimeoutSec 300
            Expand-Archive $zip $ext -Force
            $found = Get-ChildItem $ext -Filter 'ffmpeg.exe' -Recurse | Select-Object -First 1
            if ($found) { Copy-Item $found.FullName $dest -Force; $ok = $true }
            Remove-Item $zip,$ext -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-Crash "Ensure-Tool:$Name" $_ }

    if ($ok -and (Test-Path $dest)) {
        Set-CfgProp $cfg $Name $dest; Save-Config $cfg
        return $dest
    }
    return $null
}

# ================================================================
#  Helpers
# ================================================================
function Escape-WindowsCmdArg {
    param([string]$Arg)
    # Quoting Windows conforme CommandLineToArgvW :
    # - si l'argument est vide ou contient espace / tab / guillemet, on entoure de "..."
    # - chaque \ suivi d'un " est doublé, chaque " est précédé de \
    # Réf. : https://docs.microsoft.com/cpp/cpp/parsing-cpp-command-line-arguments
    if ($null -eq $Arg) { return '""' }
    if ($Arg -eq '')    { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    for ($i = 0; $i -lt $Arg.Length; $i++) {
        $c = $Arg[$i]
        if ($c -eq '\') {
            $backslashes++
        } elseif ($c -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
            [void]$sb.Append($c)
        }
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Build-WindowsCommandLine {
    param($ArgList)
    ($ArgList | ForEach-Object { Escape-WindowsCmdArg $_ }) -join ' '
}

function Clean-YouTubeUrl {
    param([string]$RawUrl)
    if (-not $RawUrl) { return '' }
    $s = $RawUrl.Trim()
    $patterns = @(
        'https?://(?:www\.|m\.)?youtube\.com/watch\?[^\s"<>]+',
        'https?://(?:www\.|m\.)?youtube\.com/playlist\?[^\s"<>]+',
        'https?://(?:www\.|m\.)?youtube\.com/shorts/[A-Za-z0-9_-]+',
        'https?://(?:www\.|m\.)?youtube\.com/embed/[A-Za-z0-9_-]+',
        'https?://youtu\.be/[A-Za-z0-9_-]+(?:\?[^\s"<>]*)?'
    )
    $matched = $null
    foreach ($p in $patterns) {
        $m = [regex]::Match($s, $p, 'IgnoreCase')
        if ($m.Success) { $matched = $m.Value; break }
    }
    if (-not $matched) { return $s }
    try { $uri = [System.Uri]$matched } catch { return $matched }
    $uriHost = $uri.Host.ToLower()
    $path    = $uri.AbsolutePath
    $query   = @{}
    if ($uri.Query) {
        foreach ($kv in $uri.Query.TrimStart('?').Split('&')) {
            if (-not $kv) { continue }
            $pts = $kv.Split('=',2); $query[$pts[0]] = if ($pts.Count -gt 1) { $pts[1] } else { '' }
        }
    }
    if ($uriHost -like '*youtu.be*') {
        $vid = $path.TrimStart('/').Split('/')[0]
        if (-not $vid) { return $matched }
        return if ($query.ContainsKey('list')) { "https://www.youtube.com/watch?v=$vid&list=$($query['list'])" } else { "https://www.youtube.com/watch?v=$vid" }
    }
    if ($path -eq '/watch') {
        if (-not $query.ContainsKey('v')) { return $matched }
        $c = "https://www.youtube.com/watch?v=$($query['v'])"
        if ($query.ContainsKey('list')) { $c += "&list=$($query['list'])" }
        return $c
    }
    if ($path -eq '/playlist') { return if ($query.ContainsKey('list')) { "https://www.youtube.com/playlist?list=$($query['list'])" } else { $matched } }
    if ($path -like '/shorts/*') { return "https://www.youtube.com/shorts/$($path.Substring('/shorts/'.Length).Split('/')[0])" }
    return $matched
}

function Detect-UrlType {
    param([string]$Url)
    if (-not $Url) { return 'unknown' }
    if ($Url -match 'youtube\.com/playlist\?') { return 'playlist' }
    if ($Url -match 'youtu\.be/|youtube\.com/shorts/|youtube\.com/watch\?') { return 'video' }
    return 'unknown'
}

function Parse-YtDlpError {
    param([string]$LogTail)
    if (-not $LogTail) { return "Download failed (unknown error)" }
    # Cherche des patterns courants dans les dernières lignes du log yt-dlp
    if ($LogTail -match 'HTTP Error 429|Too Many Requests') {
        return "YouTube rate limit reached (429). Wait a few minutes and retry."
    }
    if ($LogTail -match 'Sign in to confirm your age|age.?restricted|inappropriate for some users') {
        return "This video is age-restricted. Sign-in cookies required (not supported)."
    }
    if ($LogTail -match 'Video unavailable|has been removed|no longer available') {
        return "Video unavailable or removed."
    }
    if ($LogTail -match 'Private video|This video is private') {
        return "This video is private."
    }
    if ($LogTail -match 'This video is not available in your country|geo.?restricted|geo.?blocked') {
        return "Video geoblocked in your region. A VPN may help."
    }
    if ($LogTail -match 'members-only|available to this channel''s members') {
        return "Members-only video. Not accessible."
    }
    if ($LogTail -match 'copyright|blocked on copyright grounds') {
        return "Blocked for copyright reasons."
    }
    if ($LogTail -match 'unable to download webpage|Unable to extract|urlopen error|nodename nor servname|Network is unreachable|Temporary failure in name resolution') {
        return "Network error. Check your internet connection."
    }
    if ($LogTail -match 'Requested format is not available|no formats found') {
        return "Requested format not available for this video. Try another format."
    }
    if ($LogTail -match 'Unsupported URL') {
        return "URL not supported by yt-dlp."
    }
    if ($LogTail -match 'Login required|--cookies') {
        return "Login required to download this video."
    }
    # Extrait la première ligne d'ERROR: si présente
    $m = [regex]::Match($LogTail, 'ERROR:\s*(.+)', 'IgnoreCase')
    if ($m.Success) {
        $msg = $m.Groups[1].Value.Trim()
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '…' }
        return $msg
    }
    # Erreur ffmpeg spécifique (uniquement quand le mot est associé à un contexte d'erreur,
    # pas juste le passage de --ffmpeg-location en argument)
    if ($LogTail -match 'ffmpeg.*(error|failed|not found)' -or $LogTail -match 'Postprocessing:.*ffmpeg') {
        return "ffmpeg error during post-processing. yt-dlp update may help."
    }
    return "Download failed. Check the crash log for details."
}

function Compare-Version {
    param([string]$Va, [string]$Vb)
    # Extrait uniquement les segments numériques du début de chaque tag,
    # en ignorant tout suffixe -beta/-rc/-alpha etc. Robuste face à des tags
    # comme "v2.3.0-beta" ou "2.3.0.1".
    $extract = {
        param($v)
        $clean = $v.TrimStart('v').TrimStart('V')
        $numOnly = ($clean -split '[^0-9.]', 2)[0]  # coupe au premier caractère non-numérique/point
        $parts = @()
        foreach ($p in $numOnly.Split('.')) {
            $n = 0
            if ([int]::TryParse($p, [ref]$n)) { $parts += $n }
        }
        if ($parts.Count -eq 0) { return @(0) }
        return $parts
    }
    $a = & $extract $Va
    $b = & $extract $Vb
    $len = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $na = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $nb = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($na -lt $nb) { return -1 }; if ($na -gt $nb) { return 1 }
    }
    return 0
}

function Sanitize-Filename {
    param([string]$Name)
    if (-not $Name) { return '' }
    $s = $Name.Trim()
    # Remplace les caractères Windows interdits par un underscore
    $s = $s -replace '[\\/:*?"<>|]', '_'
    # Retire les caractères de contrôle (0x00–0x1F) qui peuvent apparaître dans certains titres YouTube exotiques
    $s = $s -replace '[\x00-\x1F]', ''
    # Neutralise les % (yt-dlp les interpréterait comme des format tokens)
    $s = $s -replace '%', '_'
    # Trim trailing dots/spaces (interdits sur Windows en fin de nom)
    $s = $s.TrimEnd(' ', '.')
    # Noms de périphériques réservés Windows (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
    if ($s -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { $s = "_$s" }
    # Limite raisonnable (Windows path max ~ 240 chars, on garde de la marge pour extension + dossier)
    if ($s.Length -gt 200) { $s = $s.Substring(0, 200) }
    if (-not $s) { $s = 'video' }
    return $s
}

# ================================================================
#  Assemblies WPF
# ================================================================
try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms   # pour FolderBrowserDialog + Toast
    Add-Type -AssemblyName System.Drawing
} catch {
    [System.Windows.MessageBox]::Show("Erreur chargement WPF : $($_.Exception.Message)")
    Write-Crash 'Add-Type' $_; return
}

# ================================================================
#  Splash "premier lancement"
# ================================================================
$cfg0         = Read-Config
# Vérifie présence dans scriptDir (bundle) OU dataDir (téléchargé auparavant)
$ytdlpFound  = (Test-Path (Join-Path $scriptDir 'yt-dlp.exe')) -or (Test-Path (Join-Path $dataDir 'yt-dlp.exe'))
$ffmpegFound = (Test-Path (Join-Path $scriptDir 'ffmpeg.exe')) -or (Test-Path (Join-Path $dataDir 'ffmpeg.exe'))

$script:splashWin = $null

if ((-not $ytdlpFound) -or (-not $ffmpegFound)) {
    $splashXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="YouTube Grabber" Height="260" Width="480"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        WindowStyle="None" Background="#121212" AllowsTransparency="True">
  <Border CornerRadius="12" Background="#121212" BorderBrush="#EF4444" BorderThickness="1">
    <StackPanel VerticalAlignment="Center" Margin="32,24">
      <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
        <Border Width="28" Height="28" CornerRadius="6" Background="#FF0000" Margin="0,0,10,0">
          <Path Data="M 0,0 L 0,11 L 10,5.5 Z" Fill="White" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="2,0,0,0"/>
        </Border>
        <TextBlock Text="YouTube Grabber" Foreground="#E8E8E8" FontFamily="Segoe UI" FontSize="16" FontWeight="Bold" VerticalAlignment="Center"/>
      </StackPanel>
      <TextBlock x:Name="SplashMsg" Text="First launch — downloading required tools..." Foreground="#9A9A9A" FontFamily="Segoe UI" FontSize="11" Margin="0,12,0,14" TextWrapping="Wrap"/>
      <ProgressBar x:Name="SplashPrg" IsIndeterminate="True" Height="5" Background="#1F1F1F" Foreground="#EF4444">
        <ProgressBar.Template>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="3" Background="{TemplateBinding Background}" ClipToBounds="True">
              <Border x:Name="PART_Indicator" CornerRadius="3" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}"/>
            </Border>
          </ControlTemplate>
        </ProgressBar.Template>
      </ProgressBar>
      <!-- Actions offline (visibles seulement en cas d'échec) -->
      <StackPanel x:Name="SplashActions" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0" Visibility="Collapsed">
        <Button x:Name="SplashManual" Width="120" Height="30" Margin="0,0,8,0">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="bd" CornerRadius="7" Background="#1F1F1F" BorderBrush="#3A3A3A" BorderThickness="1" Padding="14,0">
                <TextBlock Text="Manual install…" Foreground="#D4D4D4" FontFamily="Segoe UI" FontSize="12"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="bd" Property="Background" Value="#2A2A2A"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
        <Button x:Name="SplashRetry" Width="90" Height="30" Margin="0,0,8,0">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="bd" CornerRadius="7" Background="#1F1F1F" BorderBrush="#EF4444" BorderThickness="1" Padding="14,0">
                <TextBlock Text="↺ Retry" Foreground="#EF4444" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="bd" Property="Background" Value="#2A1414"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
        <Button x:Name="SplashClose" Width="90" Height="30">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="bd" CornerRadius="7" Background="#EF4444" Padding="14,0">
                <TextBlock Text="Close" Foreground="White" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="bd" Property="Background" Value="#F87171"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
      </StackPanel>
      <!-- Bouton de succès (visible uniquement quand tout est OK) -->
      <Button x:Name="SplashContinue" Content="Continue" Margin="0,20,0,0"
              HorizontalAlignment="Right" Width="100" Height="30" Visibility="Collapsed">
        <Button.Template>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="7" Background="#EF4444" Padding="14,0">
              <TextBlock Text="Continue" Foreground="White" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F87171"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Button.Template>
      </Button>
    </StackPanel>
  </Border>
</Window>
'@
    $script:splashWin = [Windows.Markup.XamlReader]::Parse($splashXaml)
    # Message adapté selon 1er lancement ou juste un exe manquant
    try {
        $isFirstLaunch = -not (Test-Path $configFile)
        $msgCtrl = $script:splashWin.FindName('SplashMsg')
        if ($msgCtrl -and -not $isFirstLaunch) {
            $msgCtrl.Text = 'Downloading missing tools…'
        }
    } catch {}
    $script:splashWin.Show()
    $script:splashWin.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

# Boucle Ensure-Tool avec possibilité de retry / manual install si offline
$script:splashContinue = $false

function Try-EnsureTools {
    $script:ytdlp  = Ensure-Tool -Name 'yt-dlp'  -ExeName 'yt-dlp.exe'
    $script:ffmpeg = Ensure-Tool -Name 'ffmpeg'  -ExeName 'ffmpeg.exe'
}

Try-EnsureTools
$ytdlp  = $script:ytdlp
$ffmpeg = $script:ffmpeg

if ($script:splashWin) {
    try {
        $splashMsg      = $script:splashWin.FindName('SplashMsg')
        $splashPrg      = $script:splashWin.FindName('SplashPrg')
        $splashActions  = $script:splashWin.FindName('SplashActions')
        $splashContinueBtn = $script:splashWin.FindName('SplashContinue')
        $splashRetry    = $script:splashWin.FindName('SplashRetry')
        $splashManual   = $script:splashWin.FindName('SplashManual')
        $splashClose    = $script:splashWin.FindName('SplashClose')

        $applyState = {
            if ($script:ytdlp -and $script:ffmpeg) {
                $splashMsg.Text            = 'Tools downloaded successfully ✔'
                $splashMsg.Foreground      = [Windows.Media.Brushes]::LightGreen
                $splashPrg.IsIndeterminate = $false
                $splashPrg.Value           = 100
                $splashPrg.Foreground      = [Windows.Media.Brushes]::LightGreen
                $splashActions.Visibility  = 'Collapsed'
                $splashContinueBtn.Visibility = 'Visible'
            } else {
                $missing = @()
                if (-not $script:ytdlp)  { $missing += 'yt-dlp' }
                if (-not $script:ffmpeg) { $missing += 'ffmpeg' }
                $splashMsg.Text = "Could not download: $($missing -join ', ')`nCheck your internet connection, then click Retry — or install manually."
                $splashMsg.Foreground      = [Windows.Media.Brushes]::Tomato
                $splashPrg.IsIndeterminate = $false
                $splashPrg.Value           = 100
                $splashPrg.Foreground      = [Windows.Media.Brushes]::Tomato
                $splashActions.Visibility  = 'Visible'
                $splashContinueBtn.Visibility = 'Collapsed'
            }
        }
        & $applyState

        $splashContinueBtn.Add_Click({
            $script:splashWin.Close()
            $script:splashContinue = $true
        })
        $splashClose.Add_Click({
            $script:splashWin.Close()
            $script:splashContinue = $true
        })
        $splashRetry.Add_Click({
            $splashMsg.Text            = 'Retrying…'
            $splashMsg.Foreground      = [Windows.Media.Brushes]::LightGray
            $splashPrg.IsIndeterminate = $true
            $splashPrg.Foreground      = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xEF,0x44,0x44))
            $splashActions.Visibility  = 'Collapsed'
            # Force UI refresh
            $script:splashWin.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Render)
            Try-EnsureTools
            & $applyState
        })
        $splashManual.Add_Click({
            # Ouvre les pages de release + un OpenFileDialog pour pointer manuellement les exe
            try {
                if (-not $script:ytdlp)  { Start-Process 'https://github.com/yt-dlp/yt-dlp/releases/latest' }
                if (-not $script:ffmpeg) { Start-Process 'https://github.com/GyanD/codexffmpeg/releases/latest' }
            } catch {}
            # Boîte de dialogue de sélection manuelle pour chaque exe manquant
            foreach ($tool in @('yt-dlp','ffmpeg')) {
                $exeName = "$tool.exe"
                $current = if ($tool -eq 'yt-dlp') { $script:ytdlp } else { $script:ffmpeg }
                if ($current) { continue }
                try {
                    $ofd = New-Object Microsoft.Win32.OpenFileDialog
                    $ofd.Title  = "Locate $exeName"
                    $ofd.Filter = "$exeName|$exeName|All executables (*.exe)|*.exe"
                    if ($ofd.ShowDialog()) {
                        $picked = $ofd.FileName
                        if (Test-Path $picked) {
                            $c = Read-Config
                            Set-CfgProp $c $tool $picked
                            Save-Config $c
                            if ($tool -eq 'yt-dlp') { $script:ytdlp = $picked } else { $script:ffmpeg = $picked }
                        }
                    }
                } catch {}
            }
            & $applyState
        })

        # Attend que l'user clique Continue / Close
        while (-not $script:splashContinue -and $script:splashWin.IsLoaded) {
            $script:splashWin.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
            Start-Sleep -Milliseconds 50
        }
        $ytdlp  = $script:ytdlp
        $ffmpeg = $script:ffmpeg
    } catch { try { $script:splashWin.Close() } catch {} }
    $script:splashWin = $null
}

# ================================================================
#  Config initiale
# ================================================================
$cfg0        = Read-Config
$defaultOut  = Get-CfgProp $cfg0 'lastFolder' (Join-Path $env:USERPROFILE 'Downloads')
if (-not (Test-Path $defaultOut)) { $defaultOut = Join-Path $env:USERPROFILE 'Downloads' }

$historyList = New-Object System.Collections.Generic.List[string]
$h0 = Get-CfgProp $cfg0 'history' @()
foreach ($h in $h0) { if ($h) { $historyList.Add($h) } }

# Préférences utilisateur persistées entre sessions
$prefFormat     = Get-CfgProp $cfg0 'prefFormat'    'MP3'   # MP3 / WAV / MP4
$prefPlaylist   = [bool](Get-CfgProp $cfg0 'prefPlaylist'  $false)
$prefSubs       = [bool](Get-CfgProp $cfg0 'prefSubs'      $false)
$prefMeta       = [bool](Get-CfgProp $cfg0 'prefMeta'      $true)
$prefWinW       = [int](Get-CfgProp $cfg0 'winWidth'  0)
$prefWinH       = [int](Get-CfgProp $cfg0 'winHeight' 0)
$prefWinL       = [int](Get-CfgProp $cfg0 'winLeft'  -1)
$prefWinT       = [int](Get-CfgProp $cfg0 'winTop'   -1)

function Save-HistoryUrl {
    param([string]$Url)
    $historyList.Remove($Url) | Out-Null
    $historyList.Insert(0, $Url)
    while ($historyList.Count -gt 10) { $historyList.RemoveAt($historyList.Count - 1) }
    $c = Read-Config
    Set-CfgProp $c 'history' $historyList.ToArray()
    Save-Config $c
}

# ================================================================
#  Jobs background : app-update + yt-dlp version check
# ================================================================
$script:updateJob    = $null
$script:ytdlpVerJob  = $null
$script:updateAvail  = $null

try {
    $script:updateJob = Start-Job -ScriptBlock {
        param($repo)
        try {
            $r = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing -TimeoutSec 8
            $dl = ($r.assets | Where-Object { $_.name -like '*-setup.exe' } | Select-Object -First 1).browser_download_url
            if (-not $dl) { $dl = $r.html_url }
            return [PSCustomObject]@{ Tag = $r.tag_name; Url = $dl }
        } catch { return $null }
    } -ArgumentList 'n3lio/yt-grab'
} catch {}

try {
    $script:ytdlpVerJob = Start-Job -ScriptBlock {
        try {
            $r = Invoke-RestMethod 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -UseBasicParsing -TimeoutSec 8
            return $r.tag_name
        } catch { return $null }
    }
} catch {}

# ================================================================
#  Queue item class
# ================================================================
Add-Type @'
using System.ComponentModel;
public class QueueItem : INotifyPropertyChanged {
    private string _url;
    private string _title;
    private string _customFilename;
    private string _status;
    private int    _progress;
    private string _format;
    private object _thumbnail;
    private string _speed;
    private int    _sortOrder;
    private bool   _isPlaying;
    private string _errorMessage;

    private string _outputPath;

    public string Url       { get { return _url; }       set { _url = value;       OnChanged("Url"); } }
    public string Title     { get { return _title; }     set { _title = value;     OnChanged("Title"); OnChanged("DisplayTitle"); } }
    public string CustomFilename { get { return _customFilename; } set { _customFilename = value; OnChanged("CustomFilename"); OnChanged("DisplayTitle"); } }
    public string ErrorMessage { get { return _errorMessage; } set { _errorMessage = value; OnChanged("ErrorMessage"); OnChanged("ErrorTooltip"); } }
    public string ErrorTooltip { get { return string.IsNullOrEmpty(_errorMessage) ? null : _errorMessage; } }
    public string OutputPath { get { return _outputPath; } set { _outputPath = value; OnChanged("OutputPath"); } }
    public string Status    { get { return _status; }    set { _status = value;    OnChanged("Status"); OnChanged("RetryVisible"); OnChanged("StatusColor"); OnChanged("PlayVisible"); } }
    public int    Progress  { get { return _progress; }  set { _progress = value;  OnChanged("Progress"); } }
    public string Format    { get { return _format; }    set { _format = value;    OnChanged("Format"); OnChanged("FormatColor"); OnChanged("IsAudio"); OnChanged("PlayVisible"); OnChanged("PlayIcon"); } }
    public object Thumbnail { get { return _thumbnail; } set { _thumbnail = value; OnChanged("Thumbnail"); } }
    public string Speed     { get { return _speed; }     set { _speed = value;     OnChanged("Speed"); } }
    public int    SortOrder { get { return _sortOrder; } set { _sortOrder = value; OnChanged("SortOrder"); } }
    public bool   IsPlaying { get { return _isPlaying; } set { _isPlaying = value; OnChanged("IsPlaying"); OnChanged("PlayIcon"); } }

    public string DisplayTitle {
        get {
            if (!string.IsNullOrEmpty(_customFilename)) return _customFilename;
            if (!string.IsNullOrEmpty(_title)) return _title;
            return _url;
        }
    }

    public string RetryVisible {
        get { return (_status == "Cancelled" || (_status != null && _status.StartsWith("Failed"))) ? "Visible" : "Collapsed"; }
    }

    public string StatusColor {
        get {
            if (_status == "Done")  return "#3FB950";
            if (_status == "Downloading") return "#EF4444";
            if (_status == "Cancelled")   return "#E59700";
            if (_status != null && _status.StartsWith("Failed")) return "#F85149";
            return "#8A8A8A";
        }
    }

    public string FormatColor {
        get {
            if (_format == "MP3") return "#F59E0B";
            if (_format == "WAV") return "#10B981";
            if (_format == "MP4") return "#EF4444";
            return "#8A8A8A";
        }
    }

    public bool IsAudio {
        get { return _format == "MP3" || _format == "WAV"; }
    }

    public string PlayVisible {
        get { return (_status == "Done") ? "Visible" : "Collapsed"; }
    }

    public string PlayIcon {
        // Audio (MP3/WAV) : play/pause dans l'app ; Vidéo (MP4) : ouvrir avec app par défaut
        get {
            if (_format == "MP4") return "▶";
            return _isPlaying ? "⏸" : "▶";
        }
    }

    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnChanged(string n) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(n)); }
}
'@

$queueItems = New-Object System.Collections.ObjectModel.ObservableCollection[QueueItem]

# ================================================================
#  MediaPlayer global pour preview audio
# ================================================================
$script:mediaPlayer = New-Object System.Windows.Media.MediaPlayer
$script:currentPlayingItem = $null

$script:mediaPlayer.Add_MediaEnded({
    if ($script:currentPlayingItem) {
        $script:currentPlayingItem.IsPlaying = $false
        $script:currentPlayingItem = $null
    }
})

# Reprise après crash : recharge les items depuis le config et remet "Downloading" → "Queued"
function Load-QueueFromConfig {
    $c = Read-Config
    $saved = Get-CfgProp $c 'queue' @()
    foreach ($s in $saved) {
        if (-not $s.Url) { continue }
        $item = [QueueItem]::new()
        $item.Url    = $s.Url
        $item.Title  = if ($s.Title)  { $s.Title }  else { '' }
        $item.CustomFilename = if ($s.PSObject.Properties.Name -contains 'CustomFilename' -and $s.CustomFilename) { $s.CustomFilename } else { '' }
        $item.Format = if ($s.Format) { $s.Format } else { 'MP3' }
        # "Downloading" au moment du crash → reprendre
        $item.Status   = if ($s.Status -eq 'Downloading') { 'Queued' } else { $s.Status }
        $item.Progress = if ($s.Status -eq 'Done')  { 100 }          else { 0 }
        $item.ErrorMessage = if ($s.PSObject.Properties.Name -contains 'ErrorMessage' -and $s.ErrorMessage) { $s.ErrorMessage } else { '' }
        $queueItems.Add($item)
    }
}

function Save-QueueToConfig-Now {
    # Écriture immédiate — utilisée à la fermeture uniquement
    $c = Read-Config
    $arr = @($queueItems | ForEach-Object {
        [PSCustomObject]@{ Url=$_.Url; Title=$_.Title; CustomFilename=$_.CustomFilename; Format=$_.Format; Status=$_.Status; ErrorMessage=$_.ErrorMessage }
    })
    Set-CfgProp $c 'queue' $arr
    Save-Config $c
}

# Save throttlé : marque "dirty" et flush via timer 1s (évite N writes disk si burst d'events)
$script:queueDirty = $false
$script:queueSaveTimer = $null
function Save-QueueToConfig {
    $script:queueDirty = $true
    if (-not $script:queueSaveTimer) {
        $script:queueSaveTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:queueSaveTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
        $script:queueSaveTimer.Add_Tick({
            $script:queueSaveTimer.Stop()
            if ($script:queueDirty) {
                $script:queueDirty = $false
                try { Save-QueueToConfig-Now } catch {}
            }
        })
    }
    if (-not $script:queueSaveTimer.IsEnabled) {
        $script:queueSaveTimer.Start()
    }
}

Load-QueueFromConfig

# ================================================================
#  XAML principal
# ================================================================
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="YouTube Grabber by n3lio"
    Width="820" Height="580" MinWidth="680" MinHeight="500"
    WindowStartupLocation="CenterScreen"
    Background="#0F0F0F"
    FontFamily="Segoe UI"
    WindowStyle="None"
    AllowsTransparency="True"
    ResizeMode="CanResizeWithGrip"
    AllowDrop="True"
    SnapsToDevicePixels="True"
    UseLayoutRounding="True"
    TextOptions.TextFormattingMode="Display"
    TextOptions.TextRenderingMode="ClearType">

  <Window.Resources>
    <!-- Couleurs globales -->
    <SolidColorBrush x:Key="BrBg"        Color="#0F0F0F"/>
    <SolidColorBrush x:Key="BrSurface"   Color="#1A1A1A"/>
    <SolidColorBrush x:Key="BrCard"      Color="#1F1F1F"/>
    <SolidColorBrush x:Key="BrBorder"    Color="#2E2E2E"/>
    <SolidColorBrush x:Key="BrAccent"    Color="#EF4444"/>
    <SolidColorBrush x:Key="BrAccentHov" Color="#F87171"/>
    <SolidColorBrush x:Key="BrText"      Color="#E8E8E8"/>
    <SolidColorBrush x:Key="BrMuted"     Color="#8A8A8A"/>
    <SolidColorBrush x:Key="BrOk"        Color="#3FB950"/>
    <SolidColorBrush x:Key="BrDanger"    Color="#F85149"/>
    <SolidColorBrush x:Key="BrWarn"      Color="#E59700"/>

    <!-- Style bouton principal (accent) -->
    <Style x:Key="BtnPrimary" TargetType="Button">
      <Setter Property="Background"   Value="#EF4444"/>
      <Setter Property="Foreground"   Value="White"/>
      <Setter Property="FontWeight"   Value="SemiBold"/>
      <Setter Property="FontSize"     Value="13"/>
      <Setter Property="Padding"      Value="18,0"/>
      <Setter Property="Height"       Value="38"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor"       Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="8" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F87171"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#DC2626"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#2E2E2E"/>
                <Setter TargetName="bd" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Style bouton secondaire -->
    <Style x:Key="BtnSecondary" TargetType="Button">
      <Setter Property="Background"      Value="#1F1F1F"/>
      <Setter Property="Foreground"      Value="#D4D4D4"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="Padding"         Value="14,0"/>
      <Setter Property="Height"          Value="34"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush"     Value="#2E2E2E"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <!-- TextElement.Foreground propagé explicitement pour que les enfants héritent -->
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A2A"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#4A4A4A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#161616"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Style bouton danger -->
    <Style x:Key="BtnDanger" TargetType="Button">
      <Setter Property="Background"      Value="#1F1F1F"/>
      <Setter Property="Foreground"      Value="#F85149"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="Padding"         Value="14,0"/>
      <Setter Property="Height"          Value="34"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush"     Value="#F85149"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A1414"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1A0A0A"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Style bouton ok (vert, pour relancer) -->
    <Style x:Key="BtnOk" TargetType="Button">
      <Setter Property="Background"      Value="#1F1F1F"/>
      <Setter Property="Foreground"      Value="#3FB950"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="Padding"         Value="14,0"/>
      <Setter Property="Height"          Value="34"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush"     Value="#3FB950"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#0A2A14"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- TextBox dark -->
    <Style x:Key="TxtDark" TargetType="TextBox">
      <Setter Property="Background"            Value="#1F1F1F"/>
      <Setter Property="Foreground"            Value="#E8E8E8"/>
      <Setter Property="CaretBrush"            Value="#EF4444"/>
      <Setter Property="BorderBrush"           Value="#2E2E2E"/>
      <Setter Property="BorderThickness"       Value="1"/>
      <Setter Property="Padding"               Value="10,0"/>
      <Setter Property="FontSize"              Value="12"/>
      <Setter Property="SelectionBrush"        Value="#EF4444"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#EF4444"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ComboBox dark — template complet pour harmoniser fond/bords/dropdown -->
    <Style x:Key="CmbDark" TargetType="ComboBox">
      <Setter Property="Background"      Value="#1F1F1F"/>
      <Setter Property="Foreground"      Value="#E8E8E8"/>
      <Setter Property="BorderBrush"     Value="#2E2E2E"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="ItemContainerStyle">
        <Setter.Value>
          <Style TargetType="ComboBoxItem">
            <Setter Property="Background"  Value="#1F1F1F"/>
            <Setter Property="Foreground"  Value="#E8E8E8"/>
            <Setter Property="FontSize"    Value="12"/>
            <Setter Property="Padding"     Value="10,6"/>
            <Style.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#2A2A2A"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Background" Value="#2E2E2E"/>
              </Trigger>
            </Style.Triggers>
          </Style>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="28"/>
                </Grid.ColumnDefinitions>
                <!-- Zone texte éditable -->
                <TextBox x:Name="PART_EditableTextBox" Grid.Column="0"
                         Background="Transparent" Foreground="{TemplateBinding Foreground}"
                         CaretBrush="#EF4444" SelectionBrush="#EF4444"
                         BorderThickness="0" Padding="0" Margin="0"
                         VerticalContentAlignment="Center"
                         IsReadOnly="{TemplateBinding IsReadOnly}">
                  <TextBox.Template>
                    <ControlTemplate TargetType="TextBox">
                      <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
                    </ControlTemplate>
                  </TextBox.Template>
                </TextBox>
                <!-- Bouton dropdown custom -->
                <ToggleButton Grid.Column="1" x:Name="ToggleButton" Focusable="False"
                              IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                              ClickMode="Press" Background="Transparent" BorderThickness="0" Cursor="Hand">
                  <ToggleButton.Template>
                    <ControlTemplate TargetType="ToggleButton">
                      <Border Background="Transparent">
                        <Path x:Name="arrow" Data="M 0,0 L 8,0 L 4,5 Z"
                              Fill="#8A8A8A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                          <Setter TargetName="arrow" Property="Fill" Value="#9A9A9A"/>
                        </Trigger>
                        <Trigger Property="IsChecked" Value="True">
                          <Setter TargetName="arrow" Property="Data" Value="M 0,5 L 8,5 L 4,0 Z"/>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </ToggleButton.Template>
                </ToggleButton>
                <!-- Popup dropdown -->
                <Popup x:Name="PART_Popup" Grid.ColumnSpan="2"
                       IsOpen="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}"
                       Placement="Bottom" AllowsTransparency="True" Focusable="False"
                       PopupAnimation="Slide">
                  <Border CornerRadius="7" Background="#1F1F1F" BorderBrush="#2E2E2E" BorderThickness="1"
                          MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                          MaxHeight="200">
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                      <ItemsPresenter/>
                    </ScrollViewer>
                  </Border>
                </Popup>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#EF4444"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ProgressBar dark — gradient indigo avec glow -->
    <Style x:Key="PrgDark" TargetType="ProgressBar">
      <Setter Property="Background"    Value="#1A1A1A"/>
      <Setter Property="Foreground"    Value="#EF4444"/>
      <Setter Property="Height"        Value="8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid x:Name="TemplateRoot" SnapsToDevicePixels="True">
              <Border CornerRadius="4" Background="{TemplateBinding Background}"/>
              <Border x:Name="PART_Track" CornerRadius="4" Background="Transparent"/>
              <Grid x:Name="PART_Indicator" ClipToBounds="True" HorizontalAlignment="Left">
                <Border x:Name="Indicator" CornerRadius="4">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#EF4444" Offset="0"/>
                      <GradientStop Color="#F87171" Offset="0.6"/>
                      <GradientStop Color="#FCA5A5" Offset="1"/>
                    </LinearGradientBrush>
                  </Border.Background>
                  <!-- DropShadowEffect (glow) retiré : recalculé à chaque update de Progress → coûteux -->
                </Border>
              </Grid>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ScrollBar minimaliste -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width"      Value="6"/>
      <Setter Property="Background" Value="Transparent"/>
    </Style>

    <!-- RadioButton dark -->
    <Style x:Key="RdoDark" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#D4D4D4"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="Margin"     Value="0,0,18,0"/>
      <Setter Property="Cursor"     Value="Hand"/>
    </Style>

    <!-- CheckBox dark -->
    <Style x:Key="ChkDark" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#D4D4D4"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="Margin"     Value="0,0,18,0"/>
      <Setter Property="Cursor"     Value="Hand"/>
    </Style>
  </Window.Resources>

  <!-- Fenêtre avec bord arrondi et drag -->
  <Border CornerRadius="12" Background="#0F0F0F" BorderBrush="#2E2E2E" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="42"/>   <!-- title bar -->
        <RowDefinition Height="*"/>    <!-- contenu -->
      </Grid.RowDefinitions>

      <!-- ===== TITLE BAR ===== -->
      <Border Grid.Row="0" CornerRadius="12,12,0,0" Background="#141414" x:Name="TitleBar">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <!-- Barre de progression globale en fond de la title bar -->
          <ProgressBar x:Name="PrgGlobal" Grid.ColumnSpan="2" Value="0" Maximum="100"
                       Height="42" VerticalAlignment="Stretch" HorizontalAlignment="Stretch"
                       Opacity="0.07" Background="Transparent" Foreground="#EF4444" BorderThickness="0">
            <ProgressBar.Template>
              <ControlTemplate TargetType="ProgressBar">
                <Border CornerRadius="12,12,0,0" Background="Transparent" ClipToBounds="True">
                  <Border x:Name="PART_Indicator" CornerRadius="12,0,0,0" HorizontalAlignment="Left"
                          Background="#EF4444"/>
                </Border>
              </ControlTemplate>
            </ProgressBar.Template>
          </ProgressBar>
          <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0">
            <Ellipse Width="10" Height="10" Fill="#EF4444" Margin="0,0,8,0"/>
            <TextBlock Text="YouTube Grabber" Foreground="#E8E8E8" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtVersion" Text="" Foreground="#9A9A9A" FontSize="11" VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtGlobalProgress" Text="" Foreground="#8A8A8A" FontSize="10"
                       VerticalAlignment="Center" Margin="10,0,0,0" Visibility="Collapsed"/>
            <TextBlock x:Name="TxtYtdlpVer" Text="" Foreground="#5A5A5A" FontSize="11" VerticalAlignment="Center" Margin="10,0,0,0"/>
            <TextBlock x:Name="TxtUpdateBadge" Text="" Foreground="#E59700" FontSize="11"
                       VerticalAlignment="Center" Margin="10,0,0,0" Cursor="Hand"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0">
            <Button x:Name="BtnAbout"    Width="28" Height="28" Margin="0,0,6,0" Cursor="Hand"
                    Background="#1F1F1F" BorderBrush="#2E2E2E" BorderThickness="1" ToolTip="About">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                          BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                    <TextBlock Text="?" Foreground="#D4D4D4" FontSize="13" FontWeight="Bold"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="bd" Property="Background" Value="#2A2A2A"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
            </Button>
            <Button x:Name="BtnMinimize" Width="28" Height="28" Margin="0,0,6,0" Cursor="Hand"
                    Background="#1F1F1F" BorderBrush="#2E2E2E" BorderThickness="1" ToolTip="Minimize">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                          BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                    <TextBlock Text="─" Foreground="#D4D4D4" FontSize="13"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="bd" Property="Background" Value="#2A2A2A"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
            </Button>
            <Button x:Name="BtnClose"    Width="28" Height="28" Cursor="Hand"
                    Background="#1F1F1F" BorderBrush="#F85149" BorderThickness="1" ToolTip="Close">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                          BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                    <TextBlock Text="✕" Foreground="#F85149" FontSize="12"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="bd" Property="Background" Value="#2A1414"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
            </Button>
          </StackPanel>
        </Grid>
      </Border>

      <!-- ===== CONTENU ===== -->

      <Grid Grid.Row="1" Margin="20,14,20,14">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>  <!-- URL -->
          <RowDefinition Height="Auto"/>  <!-- Preview card -->
          <RowDefinition Height="Auto"/>  <!-- Options -->
          <RowDefinition Height="Auto"/>  <!-- Destination + actions -->
          <RowDefinition Height="Auto"/>  <!-- Boutons -->
          <RowDefinition Height="*"/>     <!-- Queue -->
        </Grid.RowDefinitions>

        <!-- URL + historique -->
        <Grid Grid.Row="0" Margin="0,0,0,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <!-- Wrapper avec icône inline à gauche + bouton paste inline à droite -->
          <Border Grid.Column="0" CornerRadius="7" Background="#1F1F1F"
                  BorderBrush="#2E2E2E" BorderThickness="1" Height="38" Margin="0,0,8,0"
                  x:Name="CmbUrlBorder">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="38"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="34"/>
              </Grid.ColumnDefinitions>
              <!-- Icône YouTube (triangle play dans carré arrondi rouge) -->
              <Border Grid.Column="0" Width="22" Height="22" CornerRadius="5" Background="#FF0000"
                      HorizontalAlignment="Center" VerticalAlignment="Center" Margin="8,0,0,0">
                <Path Data="M 0,0 L 0,9 L 8,4.5 Z" Fill="White"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Margin="2,0,0,0"/>
              </Border>
              <!-- ComboBox sans bordure, s'intègre dans le wrapper -->
              <Grid Grid.Column="1">
                <ComboBox x:Name="CmbUrl" Height="36"
                          IsEditable="True" Text="" FontSize="12"
                          Background="Transparent" Foreground="#E8E8E8"
                          BorderThickness="0" VerticalContentAlignment="Center"
                          Style="{StaticResource CmbDark}"/>
                <!-- Placeholder visible quand le champ est vide -->
                <TextBlock x:Name="TxtUrlPlaceholder"
                           Text="Paste a YouTube URL here…"
                           Foreground="#5A5A5A" FontSize="12" FontStyle="Italic"
                           VerticalAlignment="Center" HorizontalAlignment="Left"
                           Margin="4,0,0,0" IsHitTestVisible="False"/>
              </Grid>
              <!-- Bouton "coller depuis presse-papier" inline -->
              <Button x:Name="BtnPasteUrl" Grid.Column="2" Width="28" Height="28"
                      VerticalAlignment="Center" HorizontalAlignment="Center"
                      Cursor="Hand" ToolTip="Paste from clipboard"
                      Background="Transparent" BorderThickness="0" Padding="0" Margin="0,0,4,0">
                <Button.Template>
                  <ControlTemplate TargetType="Button">
                    <Border x:Name="bd" CornerRadius="6" Background="#2A2A2A" BorderBrush="#3A3A3A" BorderThickness="1">
                      <TextBlock Text="📋" FontSize="13"
                                 HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="bd" Property="Background" Value="#3A3A3A"/>
                        <Setter TargetName="bd" Property="BorderBrush" Value="#EF4444"/>
                      </Trigger>
                      <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="bd" Property="Background" Value="#1F1F1F"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Button.Template>
              </Button>
            </Grid>
          </Border>
          <Button x:Name="BtnAddQueue" Grid.Column="1" Content="+ Add" Style="{StaticResource BtnPrimary}"
                  Width="100" Height="38"/>
        </Grid>

        <!-- Preview card (masqué par défaut) -->
        <Border Grid.Row="1" x:Name="PreviewCard" CornerRadius="9" Background="#1A1A1A"
                BorderBrush="#2E2E2E" BorderThickness="1" Margin="0,0,0,10"
                Visibility="Collapsed">
          <Grid Margin="12,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="100"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" CornerRadius="6" ClipToBounds="True" Width="100" Height="60">
              <Image x:Name="ImgThumb" Stretch="UniformToFill"/>
            </Border>
            <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="TxtPreviewTitle"    Foreground="#E8E8E8" FontSize="12" FontWeight="SemiBold"
                         TextTrimming="CharacterEllipsis" MaxWidth="500"/>
              <TextBlock x:Name="TxtPreviewChannel"  Foreground="#8A8A8A" FontSize="10" Margin="0,3,0,0"/>
              <TextBlock x:Name="TxtPreviewDuration" Foreground="#8A8A8A" FontSize="10" Margin="0,2,0,0"/>
              <!-- Champ de nom de fichier éditable -->
              <Grid Margin="0,6,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Filename:" Foreground="#9A9A9A" FontSize="10"
                           VerticalAlignment="Center" Margin="0,0,6,0"/>
                <Border Grid.Column="1" CornerRadius="5" Background="#161616"
                        BorderBrush="#2E2E2E" BorderThickness="1" Height="24">
                  <TextBox x:Name="TxtCustomFilename" Background="Transparent" BorderThickness="0"
                           Foreground="#E8E8E8" CaretBrush="#EF4444" FontSize="10"
                           VerticalContentAlignment="Center" Padding="6,0"
                           ToolTip="Filename used when downloading (without extension). Leave empty to use the YouTube title."/>
                </Border>
              </Grid>
              <!-- Hint playlist (visible quand une video watch appartient à une playlist) -->
              <TextBlock x:Name="TxtPreviewPlaylistHint" Margin="0,6,0,0"
                         Foreground="#F87171" FontSize="10" Visibility="Collapsed"
                         Cursor="Hand"
                         Text="This video belongs to a playlist. Click here to download the entire playlist instead."/>
            </StackPanel>
            <TextBlock x:Name="TxtPreviewLoading" Grid.ColumnSpan="2" Text="Loading preview..."
                       Foreground="#4A4A4A" FontSize="11" VerticalAlignment="Center" HorizontalAlignment="Center"
                       Visibility="Collapsed"/>
          </Grid>
        </Border>

        <!-- Options -->
        <Border Grid.Row="2" CornerRadius="9" Background="#1A1A1A" BorderBrush="#2E2E2E" BorderThickness="1"
                Margin="0,0,0,10" Padding="14,10">
          <WrapPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,24,0">
              <TextBlock Text="Format:" Foreground="#9A9A9A" FontSize="12" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <RadioButton x:Name="RdoMp3" Content="MP3 (320k)" Style="{StaticResource RdoDark}" IsChecked="True" GroupName="fmt"/>
              <RadioButton x:Name="RdoWav" Content="WAV (lossless)" Style="{StaticResource RdoDark}" GroupName="fmt"/>
              <RadioButton x:Name="RdoMp4" Content="MP4 (best)" Style="{StaticResource RdoDark}" GroupName="fmt"/>
            </StackPanel>
            <CheckBox x:Name="ChkPlaylist" Content="Full playlist"       Style="{StaticResource ChkDark}"/>
            <CheckBox x:Name="ChkSubs"     Content="Subtitles (.srt)"   Style="{StaticResource ChkDark}"/>
            <CheckBox x:Name="ChkMeta"     Content="Metadata + cover"   Style="{StaticResource ChkDark}" IsChecked="True"/>
          </WrapPanel>
        </Border>

        <!-- Destination -->
        <Grid Grid.Row="3" Margin="0,0,0,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <!-- Wrapper TextBox avec icône dossier inline -->
          <Border Grid.Column="0" CornerRadius="7" Background="#1F1F1F"
                  BorderBrush="#2E2E2E" BorderThickness="1" Height="36" Margin="0,0,8,0"
                  x:Name="TxtOutBorder">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="36"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <!-- Icône dossier SVG-style -->
              <Canvas Grid.Column="0" Width="18" Height="14" HorizontalAlignment="Center" VerticalAlignment="Center"
                      Margin="8,0,0,0">
                <Path Data="M 0,3 Q 0,1 2,1 L 6,1 L 8,3 L 16,3 Q 18,3 18,5 L 18,13 Q 18,15 16,15 L 2,15 Q 0,15 0,13 Z"
                      Fill="#9A9A9A"/>
                <Path Data="M 0,3 L 18,3 L 18,5 L 0,5 Z" Fill="#8A8A8A"/>
              </Canvas>
              <TextBox x:Name="TxtOut" Grid.Column="1" Height="34"
                       IsReadOnly="True" Background="Transparent" BorderThickness="0"
                       Foreground="#E8E8E8" FontSize="12" VerticalContentAlignment="Center"
                       Padding="4,0,8,0"/>
            </Grid>
          </Border>
          <Button x:Name="BtnBrowse" Grid.Column="1" Content="Browse" Style="{StaticResource BtnSecondary}"
                  Width="80" Margin="0,0,8,0"/>
          <Button x:Name="BtnOpen"   Grid.Column="2" Content="📂 Open" Style="{StaticResource BtnSecondary}"
                  Width="90"/>
        </Grid>

        <!-- Boutons action -->
        <Grid Grid.Row="4" Margin="0,0,0,12">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="BtnStartAll" Grid.Column="0" Content="⬇  Download all"
                  Style="{StaticResource BtnPrimary}" Width="170" Margin="0,0,8,0"
                  IsEnabled="False"/>
          <Button x:Name="BtnCancel"   Grid.Column="1" Content="✕  Cancel"
                  Style="{StaticResource BtnDanger}"   Width="110" IsEnabled="False" Margin="0,0,8,0"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,0,0">
            <TextBlock x:Name="TxtStatus" Text="Ready" Foreground="#3FB950" FontSize="12" VerticalAlignment="Center"/>
          </StackPanel>
          <Button x:Name="BtnUpdateYtdlp" Grid.Column="3" Content="↑ yt-dlp"
                  Style="{StaticResource BtnSecondary}" Width="90" Visibility="Collapsed"/>
        </Grid>

        <!-- File d'attente -->
        <Border Grid.Row="5" CornerRadius="9" Background="#1A1A1A" BorderBrush="#2E2E2E" BorderThickness="1"
                ClipToBounds="True">
          <!-- DropShadowEffect retiré ici (BlurRadius 16 très coûteux sur re-render) -->
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="32"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <!-- Header queue -->
            <Border Grid.Row="0" Background="#141414" CornerRadius="9,9,0,0" Padding="14,0">
              <!-- DropShadowEffect retiré (rebind fréquent) -->
              <Grid>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="Queue" Foreground="#9A9A9A" FontSize="12"
                             FontWeight="SemiBold" VerticalAlignment="Center"/>
                  <Border x:Name="TxtQueueCount" CornerRadius="8" Background="#242424"
                          BorderBrush="#3A3A3A" BorderThickness="1"
                          Padding="8,2" Margin="8,0,0,0" VerticalAlignment="Center"
                          Visibility="Collapsed">
                    <TextBlock x:Name="TxtQueueCountLabel" Foreground="#9A9A9A" FontSize="10" FontWeight="SemiBold"/>
                  </Border>
                </StackPanel>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <Button x:Name="BtnClearDone" Content="Clear done"
                          Style="{StaticResource BtnSecondary}" Height="26" Padding="12,0" FontSize="11"
                          VerticalAlignment="Center" Margin="0,0,6,0"/>
                </StackPanel>
              </Grid>
            </Border>
            <!-- Liste -->
            <ListView x:Name="LstQueue" Grid.Row="1" Background="Transparent" BorderThickness="0"
                      ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                      VirtualizingPanel.IsVirtualizing="True">
              <ListView.ItemContainerStyle>
                <Style TargetType="ListViewItem">
                  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                  <Setter Property="Padding"                    Value="0"/>
                  <Setter Property="Background"                 Value="Transparent"/>
                  <Setter Property="BorderThickness"            Value="0,0,0,1"/>
                  <Setter Property="BorderBrush"                Value="#1F1F1F"/>
                  <Style.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter Property="Background" Value="#1F1F1F"/>
                    </Trigger>
                    <Trigger Property="IsSelected" Value="True">
                      <Setter Property="Background" Value="#1F1F1F"/>
                    </Trigger>
                  </Style.Triggers>
                </Style>
              </ListView.ItemContainerStyle>
              <ListView.ItemTemplate>
                <DataTemplate>
                  <Grid x:Name="ItemRoot" Margin="10,5" AllowDrop="True" Background="Transparent" Opacity="0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="20"/>   <!-- drag handle + réorder -->
                      <ColumnDefinition Width="68"/>   <!-- thumbnail -->
                      <ColumnDefinition Width="*"/>    <!-- titre + url -->
                      <ColumnDefinition Width="90"/>   <!-- progress -->
                      <ColumnDefinition Width="110"/>  <!-- speed + ETA -->
                      <ColumnDefinition Width="70"/>   <!-- status -->
                      <ColumnDefinition Width="26"/>   <!-- play -->
                      <ColumnDefinition Width="26"/>   <!-- retry -->
                      <ColumnDefinition Width="26"/>   <!-- remove -->
                    </Grid.ColumnDefinitions>
                    <Grid.Triggers>
                      <EventTrigger RoutedEvent="Loaded">
                        <BeginStoryboard>
                          <Storyboard>
                            <DoubleAnimation Storyboard.TargetName="ItemRoot" Storyboard.TargetProperty="Opacity"
                                             From="0" To="1" Duration="0:0:0.25"/>
                          </Storyboard>
                        </BeginStoryboard>
                      </EventTrigger>
                    </Grid.Triggers>
                    <!-- Drag handle + boutons réorder -->
                    <StackPanel Grid.Column="0" VerticalAlignment="Center" HorizontalAlignment="Center">
                      <Button Content="▲" Tag="{Binding}" Width="16" Height="14"
                              x:Name="BtnMoveUp" Padding="0" FontSize="7" Margin="0,0,0,1"
                              Cursor="Hand" Background="Transparent" BorderThickness="0" Foreground="#4A4A4A">
                        <Button.Template>
                          <ControlTemplate TargetType="Button">
                            <Border Background="Transparent">
                              <TextBlock Text="▲" Foreground="#4A4A4A" FontSize="7"
                                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="#9A9A9A"/>
                              </Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Button.Template>
                      </Button>
                      <Button Content="▼" Tag="{Binding}" Width="16" Height="14"
                              x:Name="BtnMoveDown" Padding="0" FontSize="7"
                              Cursor="Hand" Background="Transparent" BorderThickness="0" Foreground="#4A4A4A">
                        <Button.Template>
                          <ControlTemplate TargetType="Button">
                            <Border Background="Transparent">
                              <TextBlock Text="▼" Foreground="#4A4A4A" FontSize="7"
                                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="#9A9A9A"/>
                              </Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Button.Template>
                      </Button>
                    </StackPanel>
                    <!-- Thumbnail avec badge format + overlay waveform/play -->
                    <Grid Grid.Column="1" VerticalAlignment="Center" Margin="2,0,8,0" Width="60" Height="38">
                      <!-- DropShadowEffect retiré : trop coûteux appliqué à chaque item de la queue (source de lag) -->
                      <Border CornerRadius="5" ClipToBounds="True" Background="#161616">
                        <Image Source="{Binding Thumbnail}" Stretch="UniformToFill"
                               RenderOptions.BitmapScalingMode="LowQuality"/>
                      </Border>
                      <!-- Badge format coin bas gauche -->
                      <Border x:Name="FmtBadge" CornerRadius="3,0,3,0" HorizontalAlignment="Left" VerticalAlignment="Bottom"
                              Padding="4,1" Opacity="0.92">
                        <Border.Style>
                          <Style TargetType="Border">
                            <Setter Property="Background" Value="#F59E0B"/>
                            <Style.Triggers>
                              <DataTrigger Binding="{Binding Format}" Value="WAV">
                                <Setter Property="Background" Value="#10B981"/>
                              </DataTrigger>
                              <DataTrigger Binding="{Binding Format}" Value="MP4">
                                <Setter Property="Background" Value="#EF4444"/>
                              </DataTrigger>
                            </Style.Triggers>
                          </Style>
                        </Border.Style>
                        <TextBlock Text="{Binding Format}" Foreground="White" FontSize="7" FontWeight="Bold"/>
                      </Border>
                      <!-- Waveform cosmétique (audio terminé) — 5 barres animées statiques -->
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center"
                                  Opacity="0.85">
                        <StackPanel.Style>
                          <Style TargetType="StackPanel">
                            <Setter Property="Visibility" Value="Collapsed"/>
                            <Style.Triggers>
                              <MultiDataTrigger>
                                <MultiDataTrigger.Conditions>
                                  <Condition Binding="{Binding Status}"  Value="Done"/>
                                  <Condition Binding="{Binding IsAudio}" Value="True"/>
                                </MultiDataTrigger.Conditions>
                                <Setter Property="Visibility" Value="Visible"/>
                              </MultiDataTrigger>
                            </Style.Triggers>
                          </Style>
                        </StackPanel.Style>
                        <Border Width="3" Height="8"  CornerRadius="2" Background="#FCA5A5" Margin="1,0" VerticalAlignment="Center"/>
                        <Border Width="3" Height="18" CornerRadius="2" Background="#F87171" Margin="1,0" VerticalAlignment="Center"/>
                        <Border Width="3" Height="12" CornerRadius="2" Background="#EF4444" Margin="1,0" VerticalAlignment="Center"/>
                        <Border Width="3" Height="22" CornerRadius="2" Background="#F87171" Margin="1,0" VerticalAlignment="Center"/>
                        <Border Width="3" Height="10" CornerRadius="2" Background="#FCA5A5" Margin="1,0" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Grid>
                    <!-- Titre + URL -->
                    <StackPanel Grid.Column="2" VerticalAlignment="Center">
                      <TextBlock Text="{Binding DisplayTitle}" Foreground="#E8E8E8" FontSize="12"
                                 TextTrimming="CharacterEllipsis" FontWeight="Medium"/>
                      <TextBlock Text="{Binding Url}" Foreground="#4A4A4A" FontSize="9"
                                 TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                    <!-- ProgressBar gradient -->
                    <ProgressBar Grid.Column="3" Value="{Binding Progress}" Maximum="100" Minimum="0"
                                 Style="{StaticResource PrgDark}" Height="8" VerticalAlignment="Center" Margin="6,0"/>
                    <!-- Vitesse -->
                    <TextBlock Grid.Column="4" Text="{Binding Speed}" Foreground="#8A8A8A"
                               FontSize="9" VerticalAlignment="Center" HorizontalAlignment="Center"
                               TextAlignment="Center"/>
                    <!-- Status badge (tooltip = message d'erreur si Failed) -->
                    <Border Grid.Column="5" CornerRadius="5" Padding="6,3" VerticalAlignment="Center" HorizontalAlignment="Center"
                            ToolTip="{Binding ErrorTooltip}">
                      <Border.Style>
                        <Style TargetType="Border">
                          <Setter Property="Background" Value="#181818"/>
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding Status}" Value="Done">
                              <Setter Property="Background" Value="#0D2B18"/>
                            </DataTrigger>
                            <DataTrigger Binding="{Binding Status}" Value="Downloading">
                              <Setter Property="Background" Value="#2A1414"/>
                            </DataTrigger>
                            <DataTrigger Binding="{Binding Status}" Value="Cancelled">
                              <Setter Property="Background" Value="#2A1E08"/>
                            </DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </Border.Style>
                      <TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}"
                                 FontSize="10" FontWeight="SemiBold" MaxWidth="58"
                                 TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" TextAlignment="Center"/>
                    </Border>
                    <!-- Play (audio terminé) -->
                    <Button Grid.Column="6" Tag="{Binding}" Width="22" Height="22"
                            x:Name="BtnPlayItem" Padding="0" FontSize="9"
                            VerticalAlignment="Center" HorizontalAlignment="Center"
                            Visibility="{Binding PlayVisible}"
                            Cursor="Hand">
                      <Button.Template>
                        <ControlTemplate TargetType="Button">
                          <Border x:Name="bd" CornerRadius="5" Background="#242424"
                                  BorderBrush="#EF4444" BorderThickness="1">
                            <TextBlock Text="{Binding PlayIcon}" Foreground="#F87171" FontSize="9"
                                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
                          </Border>
                          <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                              <Setter TargetName="bd" Property="Background" Value="#2E2E2E"/>
                            </Trigger>
                          </ControlTemplate.Triggers>
                        </ControlTemplate>
                      </Button.Template>
                    </Button>
                    <!-- Retry -->
                    <Button Grid.Column="7" Content="↺" Tag="{Binding}" Width="22" Height="22"
                            x:Name="BtnRetryItem" Style="{StaticResource BtnOk}" Padding="0" FontSize="12"
                            VerticalAlignment="Center" HorizontalAlignment="Center"
                            Visibility="{Binding RetryVisible}"/>
                    <!-- Remove -->
                    <Button Grid.Column="8" Content="✕" Tag="{Binding}" Width="22" Height="22"
                            x:Name="BtnRemoveItem" Style="{StaticResource BtnDanger}" Padding="0" FontSize="10"
                            VerticalAlignment="Center" HorizontalAlignment="Center"/>
                  </Grid>
                </DataTemplate>
              </ListView.ItemTemplate>
            </ListView>
            <!-- Placeholder queue vide -->
            <TextBlock Grid.Row="1" x:Name="TxtQueueEmpty"
                       Text="Paste a URL above and click + Add"
                       Foreground="#5A5A5A" FontSize="12" FontStyle="Italic"
                       HorizontalAlignment="Center"
                       VerticalAlignment="Center" IsHitTestVisible="False"/>
          </Grid>
        </Border>
      </Grid>


    </Grid>
  </Border>
</Window>
'@

# ================================================================
#  Parse XAML + bind contrôles
# ================================================================
try {
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.MessageBox]::Show("Erreur XAML : $($_.Exception.Message)`n`n$($_.ScriptStackTrace)")
    Write-Crash 'XamlReader.Load' $_; return
}

function Find-Ctrl { param([string]$Name) $window.FindName($Name) }

$TitleBar        = Find-Ctrl 'TitleBar'
$TxtVersion      = Find-Ctrl 'TxtVersion'
$TxtUpdateBadge  = Find-Ctrl 'TxtUpdateBadge'
$BtnAbout        = Find-Ctrl 'BtnAbout'
$BtnMinimize     = Find-Ctrl 'BtnMinimize'
$BtnClose        = Find-Ctrl 'BtnClose'
$CmbUrl          = Find-Ctrl 'CmbUrl'
$BtnAddQueue          = Find-Ctrl 'BtnAddQueue'
$BtnPasteUrl          = Find-Ctrl 'BtnPasteUrl'
$TxtUrlPlaceholder    = Find-Ctrl 'TxtUrlPlaceholder'
$PreviewCard     = Find-Ctrl 'PreviewCard'
$ImgThumb        = Find-Ctrl 'ImgThumb'
$TxtPreviewTitle  = Find-Ctrl 'TxtPreviewTitle'
$TxtPreviewChannel= Find-Ctrl 'TxtPreviewChannel'
$TxtPreviewDuration=Find-Ctrl 'TxtPreviewDuration'
$TxtPreviewLoading= Find-Ctrl 'TxtPreviewLoading'
$TxtCustomFilename= Find-Ctrl 'TxtCustomFilename'
$TxtPreviewPlaylistHint = Find-Ctrl 'TxtPreviewPlaylistHint'
$RdoMp3          = Find-Ctrl 'RdoMp3'
$RdoWav          = Find-Ctrl 'RdoWav'
$RdoMp4          = Find-Ctrl 'RdoMp4'
$PrgGlobal       = Find-Ctrl 'PrgGlobal'
$TxtGlobalProgress = Find-Ctrl 'TxtGlobalProgress'
$ChkPlaylist     = Find-Ctrl 'ChkPlaylist'
$ChkSubs         = Find-Ctrl 'ChkSubs'
$ChkMeta         = Find-Ctrl 'ChkMeta'
$TxtOut          = Find-Ctrl 'TxtOut'
$BtnBrowse       = Find-Ctrl 'BtnBrowse'
$BtnOpen         = Find-Ctrl 'BtnOpen'
$BtnStartAll     = Find-Ctrl 'BtnStartAll'
$BtnCancel       = Find-Ctrl 'BtnCancel'
$TxtStatus       = Find-Ctrl 'TxtStatus'
$BtnUpdateYtdlp  = Find-Ctrl 'BtnUpdateYtdlp'
$LstQueue        = Find-Ctrl 'LstQueue'
$TxtQueueEmpty   = Find-Ctrl 'TxtQueueEmpty'
$BtnClearDone        = Find-Ctrl 'BtnClearDone'
$TxtYtdlpVer         = Find-Ctrl 'TxtYtdlpVer'
$TxtQueueCount       = Find-Ctrl 'TxtQueueCount'
$TxtQueueCountLabel  = Find-Ctrl 'TxtQueueCountLabel'

# ================================================================
#  Helpers UI (définis après parse XAML, avant tout appel)
# ================================================================
function Update-GlobalProgress {
    $total = $queueItems.Count
    if ($total -eq 0) {
        $PrgGlobal.Value = 0
        $TxtGlobalProgress.Visibility = 'Collapsed'
        return
    }
    # Une seule passe : calcule à la fois "done" et "total progress"
    $done = 0
    $totalProgress = 0
    foreach ($item in $queueItems) {
        if ($item.Status -eq 'Done') {
            $done++
            $totalProgress += 100
        } elseif ($item.Status -eq 'Downloading') {
            $totalProgress += $item.Progress
        }
        # Queued / Cancelled / Failed = 0%
    }
    $pct = [int]($totalProgress / $total)
    $PrgGlobal.Value = $pct
    $TxtGlobalProgress.Text       = "$done/$total"
    $TxtGlobalProgress.Visibility = 'Visible'
}

function Update-QueueCounter {
    # Une seule passe pour compter — évite 3× Where-Object + .Count
    $total = $queueItems.Count
    $done = 0; $pending = 0; $running = 0
    foreach ($it in $queueItems) {
        switch ($it.Status) {
            'Done'        { $done++ }
            'Queued'      { $pending++ }
            'Downloading' { $running++ }
        }
    }
    if ($total -gt 0) {
        $TxtQueueCountLabel.Text    = "$done/$total"
        $TxtQueueCount.Visibility   = 'Visible'
        # Couleur selon état
        if ($running -gt 0)      { $TxtQueueCountLabel.Foreground = '#F87171' }
        elseif ($done -eq $total){ $TxtQueueCountLabel.Foreground = '#3FB950' }
        elseif ($pending -gt 0)  { $TxtQueueCountLabel.Foreground = '#9A9A9A' }
        else                     { $TxtQueueCountLabel.Foreground = '#8A8A8A' }
    } else {
        $TxtQueueCount.Visibility = 'Collapsed'
    }
    # Sync état "Download all" en même temps (évite un 2e scan)
    if ($script:running) {
        $BtnStartAll.IsEnabled = $false
    } else {
        $BtnStartAll.IsEnabled = ($pending -gt 0)
    }
}

# Init valeurs
$TxtVersion.Text = " v$AppVersion"
# (Le version log a été retiré en v2.3.0 — sans valeur pour le debug, seul le crash log est conservé.)

# Note: pas de cleanup au démarrage pour éviter de supprimer des fichiers utilisateur
# Le cleanup se fait seulement après chaque download (voir timer Tick)
$TxtOut.Text     = $defaultOut
foreach ($h in $historyList) { $CmbUrl.Items.Add($h) | Out-Null }
$LstQueue.ItemsSource = $queueItems
if ($queueItems.Count -gt 0) {
    $TxtQueueEmpty.Visibility = 'Collapsed'
}
# Restore préférences utilisateur (format, options, taille/position fenêtre)
switch ($prefFormat) {
    'WAV' { $RdoWav.IsChecked = $true }
    'MP4' { $RdoMp4.IsChecked = $true }
    default { $RdoMp3.IsChecked = $true }
}
$ChkPlaylist.IsChecked = $prefPlaylist
$ChkSubs.IsChecked     = $prefSubs
$ChkMeta.IsChecked     = $prefMeta
if ($prefWinW -ge 680 -and $prefWinH -ge 500) {
    $window.Width  = $prefWinW
    $window.Height = $prefWinH
}
if ($prefWinL -ge 0 -and $prefWinT -ge 0) {
    # Sanity check : la fenêtre doit rester au moins partiellement visible sur un écran
    try {
        $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
        $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($prefWinL -lt $vw - 100 -and $prefWinT -lt $vh - 100) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = $prefWinL
            $window.Top  = $prefWinT
        }
    } catch {}
}

# Handlers pour persister les préférences dès qu'elles changent
function Save-UserPreferences {
    try {
        $c = Read-Config
        $fmt = if ($RdoMp3.IsChecked) { 'MP3' } elseif ($RdoWav.IsChecked) { 'WAV' } else { 'MP4' }
        Set-CfgProp $c 'prefFormat'   $fmt
        Set-CfgProp $c 'prefPlaylist' ([bool]$ChkPlaylist.IsChecked)
        Set-CfgProp $c 'prefSubs'     ([bool]$ChkSubs.IsChecked)
        Set-CfgProp $c 'prefMeta'     ([bool]$ChkMeta.IsChecked)
        Save-Config $c
    } catch {}
}
$RdoMp3.Add_Checked({ Save-UserPreferences })
$RdoWav.Add_Checked({ Save-UserPreferences })
$RdoMp4.Add_Checked({ Save-UserPreferences })
$ChkPlaylist.Add_Checked({   Save-UserPreferences })
$ChkPlaylist.Add_Unchecked({ Save-UserPreferences })
$ChkSubs.Add_Checked({       Save-UserPreferences })
$ChkSubs.Add_Unchecked({     Save-UserPreferences })
$ChkMeta.Add_Checked({       Save-UserPreferences })
$ChkMeta.Add_Unchecked({     Save-UserPreferences })

# Toujours appeler Update-QueueCounter pour synchroniser l'état de "Download all"
Update-GlobalProgress
Update-QueueCounter

# ================================================================
#  Helper — modale dark (remplace MessageBox.Show)
# ================================================================
function Show-DarkDialog {
    param([string]$Message, [string]$Title='YouTube Grabber', [string]$Icon='ℹ')
    $iconColor = switch ($Icon) {
        '⚠' { '#E59700' }; '✕' { '#F85149' }; '✔' { '#3FB950' }; default { '#EF4444' }
    }
    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" SizeToContent="Height" Width="360"
        WindowStartupLocation="CenterOwner"
        Background="#0F0F0F" FontFamily="Segoe UI"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize">
  <Border CornerRadius="12" Background="#0F0F0F" BorderBrush="#2E2E2E" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="38"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="52"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" CornerRadius="12,12,0,0" Background="#141414" x:Name="DlgBar">
        <TextBlock Text="$Title" Foreground="#E8E8E8" FontSize="12" FontWeight="SemiBold"
                   VerticalAlignment="Center" Margin="16,0"/>
      </Border>
      <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="20,16">
        <TextBlock Text="$Icon" Foreground="$iconColor" FontSize="22" VerticalAlignment="Top" Margin="0,0,14,0"/>
        <TextBlock Text="$Message" Foreground="#D4D4D4" FontSize="12" TextWrapping="Wrap"
                   VerticalAlignment="Center" MaxWidth="270"/>
      </StackPanel>
      <Border Grid.Row="2" CornerRadius="0,0,12,12" Background="#141414">
        <Button x:Name="DlgOk" Width="90" Height="32" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="bd" CornerRadius="7" Background="#EF4444">
                <TextBlock Text="OK" Foreground="White" FontSize="12" FontWeight="SemiBold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="bd" Property="Background" Value="#F87171"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
      </Border>
    </Grid>
  </Border>
</Window>
"@
    try {
        $dlg = [Windows.Markup.XamlReader]::Parse($dlgXaml)
        $dlg.Owner = $window
        $dlg.FindName('DlgBar').Add_MouseLeftButtonDown({ $dlg.DragMove() })
        $dlg.FindName('DlgOk').Add_Click({ $dlg.Close() })
        $dlg.ShowDialog() | Out-Null
    } catch {}
}

# ================================================================
#  Drag fenêtre sans bordure
# ================================================================
$TitleBar.Add_MouseLeftButtonDown({ $window.DragMove() })

# ================================================================
#  Boutons titre
# ================================================================
$BtnClose.Add_Click({
    # Stop MediaPlayer si en cours
    if ($script:mediaPlayer) {
        try { $script:mediaPlayer.Stop(); $script:mediaPlayer.Close() } catch {}
    }
    # Quitter vraiment l'application
    [System.Windows.Application]::Current.Shutdown()
})
$BtnMinimize.Add_Click({ $window.WindowState = 'Minimized' })

$BtnAbout.Add_Click({
    try {
        $aboutXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="About" Width="400" Height="300"
        WindowStartupLocation="CenterOwner"
        Background="#0F0F0F" FontFamily="Segoe UI"
        WindowStyle="None" AllowsTransparency="True"
        ResizeMode="NoResize">
  <Border CornerRadius="12" Background="#0F0F0F" BorderBrush="#2E2E2E" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="40"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="60"/>
      </Grid.RowDefinitions>

      <!-- Title bar -->
      <Border Grid.Row="0" CornerRadius="12,12,0,0" Background="#141414" x:Name="AboutTitleBar">
        <Grid Margin="16,0">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="8" Height="8" Fill="#EF4444" Margin="0,0,8,0"/>
            <TextBlock Text="About" Foreground="#E8E8E8" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </StackPanel>
          <Button x:Name="BtnAboutClose" Width="26" Height="26" HorizontalAlignment="Right" VerticalAlignment="Center"
                  Background="#1F1F1F" BorderBrush="#F85149" BorderThickness="1" Cursor="Hand">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border x:Name="bd" CornerRadius="6" Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                  <TextBlock Text="✕" Foreground="#F85149" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="bd" Property="Background" Value="#2A1414"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Button.Template>
          </Button>
        </Grid>
      </Border>

      <!-- Content -->
      <StackPanel Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center" Margin="30,0">
        <!-- Logo area -->
        <Border CornerRadius="16" Background="#FF0000" BorderBrush="#CC0000" BorderThickness="1"
                Width="64" Height="64" HorizontalAlignment="Center" Margin="0,0,0,16">
          <Path Data="M 0,0 L 0,22 L 20,11 Z" Fill="White" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="3,0,0,0"/>
        </Border>
        <TextBlock Text="YouTube Grabber" Foreground="#E8E8E8" FontSize="18" FontWeight="Bold"
                   HorizontalAlignment="Center"/>
        <TextBlock x:Name="AboutVersion" Foreground="#EF4444" FontSize="12" HorizontalAlignment="Center" Margin="0,4,0,0"/>
        <TextBlock Text="by n3lio" Foreground="#8A8A8A" FontSize="11" HorizontalAlignment="Center" Margin="0,2,0,16"/>
        <TextBlock Text="Powered by yt-dlp + ffmpeg" Foreground="#4A4A4A" FontSize="10"
                   HorizontalAlignment="Center"/>
        <TextBlock x:Name="AboutRepo" Foreground="#EF4444" FontSize="10" HorizontalAlignment="Center"
                   Margin="0,4,0,0" Cursor="Hand" TextDecorations="Underline"/>
      </StackPanel>

      <!-- Footer OK button -->
      <Border Grid.Row="2" CornerRadius="0,0,12,12" Background="#141414">
        <Button x:Name="BtnAboutOk" Content="Close" Width="110" Height="34"
                HorizontalAlignment="Center" VerticalAlignment="Center">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="bd" CornerRadius="8" Background="#EF4444" Padding="18,0">
                <TextBlock Text="Close" Foreground="White" FontSize="12" FontWeight="SemiBold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="bd" Property="Background" Value="#F87171"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                  <Setter TargetName="bd" Property="Background" Value="#DC2626"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
      </Border>
    </Grid>
  </Border>
</Window>
"@
        $aboutWin        = [Windows.Markup.XamlReader]::Parse($aboutXaml)
        $aboutWin.Owner  = $window

        # Bind values
        $aboutWin.FindName('AboutVersion').Text = "v$AppVersion"
        $repoTxt = $aboutWin.FindName('AboutRepo')
        $repoTxt.Text = $AppRepo
        $repoTxt.Add_MouseLeftButtonDown({ Start-Process $AppRepo })

        # Drag
        $aboutWin.FindName('AboutTitleBar').Add_MouseLeftButtonDown({ $aboutWin.DragMove() })

        # Boutons
        $aboutWin.FindName('BtnAboutClose').Add_Click({ $aboutWin.Close() })
        $aboutWin.FindName('BtnAboutOk').Add_Click({ $aboutWin.Close() })

        $aboutWin.ShowDialog() | Out-Null
    } catch { Write-Crash 'BtnAbout' $_ }
})

# ================================================================
#  Raccourci Entrée sur l'URL → Ajouter
#  (PreviewKeyDown bubble depuis le TextBox interne du ComboBox)
# ================================================================
$CmbUrl.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') {
        $e.Handled = $true
        $BtnAddQueue.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

# ================================================================
#  Bouton "Paste from clipboard" — colle directement le contenu du presse-papier
# ================================================================
$BtnPasteUrl.Add_Click({
    try {
        $clip = ''
        try { $clip = [System.Windows.Clipboard]::GetText() } catch {}
        if (-not $clip) {
            try { $clip = [System.Windows.Forms.Clipboard]::GetText() } catch {}
        }
        if ($clip) {
            $CmbUrl.Text = $clip.Trim()
            # Positionne le caret en fin et redonne le focus au champ
            try {
                $CmbUrl.Focus()
                $inner = $CmbUrl.Template.FindName('PART_EditableTextBox', $CmbUrl)
                if ($inner) {
                    $inner.CaretIndex = $inner.Text.Length
                    $inner.Focus() | Out-Null
                }
            } catch {}
        }
    } catch { Write-Crash 'BtnPasteUrl' $_ }
})

# ================================================================
#  Drag & drop URL depuis le navigateur → fenêtre
# ================================================================
$window.Add_DragOver({
    param($s, $e)
    $e.Effects = if ($e.Data.GetDataPresent([System.Windows.DataFormats]::UnicodeText) -or
                     $e.Data.GetDataPresent([System.Windows.DataFormats]::Text)) {
        [System.Windows.DragDropEffects]::Copy
    } else { [System.Windows.DragDropEffects]::None }
    $e.Handled = $true
})
$window.Add_Drop({
    param($s, $e)
    try {
        $txt = if ($e.Data.GetDataPresent([System.Windows.DataFormats]::UnicodeText)) {
            $e.Data.GetData([System.Windows.DataFormats]::UnicodeText)
        } else {
            $e.Data.GetData([System.Windows.DataFormats]::Text)
        }
        if ($txt -match 'https?://') {
            $CmbUrl.Text = $txt.Trim()
            $CmbUrl.Focus()
        }
    } catch {}
})

# ================================================================
#  Raccourcis clavier globaux
#  - Delete : retire l'item sélectionné dans la queue (si pas Downloading)
#  - F5     : retry tous les Failed
#  - Escape : ferme la fenêtre principale
# ================================================================
$window.Add_PreviewKeyDown({
    param($s, $e)
    try {
        # Delete → retirer l'item sélectionné dans la queue
        if ($e.Key -eq 'Delete') {
            $sel = $LstQueue.SelectedItem -as [QueueItem]
            if ($sel -and $sel.Status -ne 'Downloading') {
                if ($script:currentPlayingItem -and ($script:currentPlayingItem -eq $sel)) {
                    try { $script:mediaPlayer.Stop() } catch {}
                    $sel.IsPlaying = $false
                    $script:currentPlayingItem = $null
                }
                $queueItems.Remove($sel) | Out-Null
                if ($queueItems.Count -eq 0) { $TxtQueueEmpty.Visibility = 'Visible' }
                Save-QueueToConfig
                Update-QueueCounter
                $e.Handled = $true
            }
        }
        # F5 → retry tous les Failed
        elseif ($e.Key -eq 'F5') {
            $anyRetry = $false
            foreach ($it in $queueItems) {
                if ($it.Status -and $it.Status.StartsWith('Failed')) {
                    $it.Status = 'Queued'; $it.Progress = 0; $it.Speed = ''; $it.ErrorMessage = ''
                    $anyRetry = $true
                }
            }
            if ($anyRetry) {
                Save-QueueToConfig
                Update-QueueCounter
                $e.Handled = $true
            }
        }
        # Escape → fermer (uniquement si aucun modal ouvert, ce que WPF gère nativement)
        elseif ($e.Key -eq 'Escape' -and -not $CmbUrl.IsKeyboardFocusWithin -and -not ($TxtCustomFilename -and $TxtCustomFilename.IsKeyboardFocusWithin)) {
            $window.Close()
            $e.Handled = $true
        }
    } catch { Write-Crash 'GlobalKeyDown' $_ }
})

# ================================================================
#  Update badge (cliquable) — télécharge + lance l'installer
# ================================================================
$TxtUpdateBadge.Add_MouseLeftButtonDown({
    if (-not $script:updateAvail) { return }
    $url = $script:updateAvail.Url
    $tag = $script:updateAvail.Tag

    # Si c'est un lien direct vers setup.exe → on propose de télécharger + lancer
    # Si c'est la page releases → on ouvre simplement le navigateur
    $isSetup = $url -match '\.exe$'

    if ($isSetup) {
        # Modale de confirmation dark
        $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Update available" SizeToContent="Height" Width="380"
        WindowStartupLocation="CenterOwner"
        Background="#0F0F0F" FontFamily="Segoe UI"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize">
  <Border CornerRadius="12" Background="#0F0F0F" BorderBrush="#2E2E2E" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="38"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="56"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" CornerRadius="12,12,0,0" Background="#141414" x:Name="UpdBar">
        <TextBlock Text="Update available" Foreground="#E8E8E8" FontSize="12" FontWeight="SemiBold"
                   VerticalAlignment="Center" Margin="16,0"/>
      </Border>
      <StackPanel Grid.Row="1" Margin="20,16">
        <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
          <TextBlock Text="⬆" Foreground="#E59700" FontSize="22" VerticalAlignment="Top" Margin="0,0,12,0"/>
          <TextBlock Foreground="#D4D4D4" FontSize="12" TextWrapping="Wrap" MaxWidth="290">
            <Run Text="YouTube Grabber "/>
            <Run x:Name="UpdVerRun" FontWeight="Bold" Foreground="#F87171"/>
            <Run Text=" is available."/>
            <LineBreak/>
            <Run Text="The installer will be downloaded. The app will close to apply the update." Foreground="#9A9A9A" FontSize="11"/>
          </TextBlock>
        </StackPanel>
      </StackPanel>
      <Border Grid.Row="2" CornerRadius="0,0,12,12" Background="#141414">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Button x:Name="UpdOk" Width="130" Height="32" Margin="0,0,10,0">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border x:Name="bd" CornerRadius="7" Background="#EF4444">
                  <TextBlock Text="⬇ Update now" Foreground="White" FontSize="12" FontWeight="SemiBold"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="bd" Property="Background" Value="#F87171"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Button.Template>
          </Button>
          <Button x:Name="UpdCancel" Width="80" Height="32">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border x:Name="bd" CornerRadius="7" Background="#1F1F1F" BorderBrush="#2E2E2E" BorderThickness="1">
                  <TextBlock Text="Later" Foreground="#9A9A9A" FontSize="12"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="bd" Property="Background" Value="#2A2A2A"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Button.Template>
          </Button>
        </StackPanel>
      </Border>
    </Grid>
  </Border>
</Window>
"@
        try {
            $dlg = [Windows.Markup.XamlReader]::Parse($dlgXaml)
            $dlg.Owner = $window
            $dlg.FindName('UpdBar').Add_MouseLeftButtonDown({ $dlg.DragMove() })
            # Set version text inline
            $verRun = $dlg.FindName('UpdVerRun')
            if ($verRun) { $verRun.Text = $tag }
            $script:confirmed = $false
            $dlg.FindName('UpdOk').Add_Click({ $script:confirmed = $true; $dlg.Close() })
            $dlg.FindName('UpdCancel').Add_Click({ $dlg.Close() })
            $dlg.ShowDialog() | Out-Null

            if ($script:confirmed) {
                $script:confirmed = $false
                # Téléchargement en background, puis lancement + fermeture app
                $TxtUpdateBadge.Text = '⬇ Downloading...'
                $dlUrl = $url
                $script:autoUpdateJob = Start-Job -ScriptBlock {
                    param($downloadUrl, $tag)
                    try {
                        $dest = Join-Path $env:TEMP "yt-grab-$tag-setup.exe"
                        Invoke-WebRequest $downloadUrl -OutFile $dest -UseBasicParsing -TimeoutSec 180
                        return $dest
                    } catch { return $null }
                } -ArgumentList $dlUrl, $tag
            }
        } catch {}
    } else {
        # Lien page releases — ouvre dans le navigateur
        Start-Process $url
    }
})

# ================================================================
#  Détection URL en temps réel → preview + auto-playlist
#  (Débouncé pour éviter de spawner un job PowerShell par frappe)
# ================================================================
$script:previewJob   = $null
$script:lastPreviewUrl = ''
$script:pendingPreviewUrl = ''
$script:filenameUserEdited = $false
$script:suppressFilenameChanged = $false

# Timer de debounce (400ms) — on ne lance la preview que quand l'utilisateur
# arrête de taper, pas à chaque frappe. Évite N processes PowerShell zombis
# et les micro-freezes de l'UI.
$script:previewDebounceTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:previewDebounceTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:previewDebounceTimer.Add_Tick({
    $script:previewDebounceTimer.Stop()
    $cleaned = $script:pendingPreviewUrl
    if (-not $cleaned -or $cleaned -eq $script:lastPreviewUrl) { return }
    $script:lastPreviewUrl = $cleaned
    if ($script:previewJob) {
        try { Stop-Job $script:previewJob -ErrorAction SilentlyContinue; Remove-Job $script:previewJob -Force -ErrorAction SilentlyContinue } catch {}
    }
    $ytdlpPath = $ytdlp
    # Le job télécharge aussi la thumbnail en bytes — évite le WebClient.DownloadData
    # sur le UI thread qui causait des micro-freezes 100-500 ms selon la connexion.
    $script:previewJob = Start-Job -ScriptBlock {
        param($ytPath, $url)
        try {
            $json = & $ytPath --dump-json --no-playlist --no-warnings $url 2>$null | Select-Object -First 1
            if (-not $json) { return $null }
            $info = $json | ConvertFrom-Json
            $thumbBytes = $null
            if ($info.thumbnail) {
                try {
                    $wc = New-Object System.Net.WebClient
                    $thumbBytes = $wc.DownloadData($info.thumbnail)
                } catch {}
            }
            return [PSCustomObject]@{
                title      = $info.title
                artist     = $info.artist
                creator    = $info.creator
                uploader   = $info.uploader
                duration   = $info.duration
                thumbBytes = $thumbBytes
            }
        } catch {}
        return $null
    } -ArgumentList $ytdlpPath, $cleaned
})

# WPF ComboBox editable : pas de Add_TextChanged direct, on passe par le routed event
$CmbUrl.AddHandler(
    [System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
    [System.Windows.Controls.TextChangedEventHandler]{
        try {
            $raw      = $CmbUrl.Text.Trim()
            # Placeholder
            if ($TxtUrlPlaceholder) {
                $TxtUrlPlaceholder.Visibility = if ($raw -eq '') { 'Visible' } else { 'Collapsed' }
            }
            $detected = Detect-UrlType $raw
            if ($detected -eq 'playlist')  { $ChkPlaylist.IsChecked = $true }
            elseif ($detected -eq 'video') { $ChkPlaylist.IsChecked = $false }

            # Hint "download entire playlist" quand watch URL contient &list= (mais pas playlist? direct)
            if ($TxtPreviewPlaylistHint) {
                if ($detected -eq 'video' -and $raw -match '[?&]list=') {
                    $TxtPreviewPlaylistHint.Visibility = 'Visible'
                } else {
                    $TxtPreviewPlaylistHint.Visibility = 'Collapsed'
                }
            }

            $cleaned = Clean-YouTubeUrl $raw
            if ($cleaned -ne $script:lastPreviewUrl -and $cleaned -match '^https?://') {
                # Prépare l'affichage "Loading" immédiatement pour donner du feedback,
                # mais reporte le lancement du job via le debounce timer.
                $PreviewCard.Visibility       = 'Visible'
                $TxtPreviewLoading.Visibility = 'Visible'
                $ImgThumb.Source              = $null
                $TxtPreviewTitle.Text         = ''
                $TxtPreviewChannel.Text       = ''
                $TxtPreviewDuration.Text      = ''
                # Reset du champ filename SEULEMENT s'il n'a pas été édité manuellement
                # (préserve le travail de l'utilisateur quand il modifie l'URL après avoir tapé un nom)
                if (-not $script:filenameUserEdited -and $TxtCustomFilename) {
                    $script:suppressFilenameChanged = $true
                    try { $TxtCustomFilename.Text = '' } finally { $script:suppressFilenameChanged = $false }
                }
                # Restart the debounce timer (Stop puis Start reset le compteur)
                $script:pendingPreviewUrl = $cleaned
                $script:previewDebounceTimer.Stop()
                $script:previewDebounceTimer.Start()
            } elseif ($cleaned -notmatch '^https?://') {
                $PreviewCard.Visibility = 'Collapsed'
                $script:previewDebounceTimer.Stop()
                $script:pendingPreviewUrl = ''
            }
        } catch {}
    }
)

# ================================================================
#  Suivi édition manuelle du champ filename
# ================================================================
if ($TxtCustomFilename) {
    $TxtCustomFilename.Add_TextChanged({
        if (-not $script:suppressFilenameChanged) {
            $script:filenameUserEdited = $true
        }
    })
}

# Click sur le hint "download entire playlist" → coche playlist + masque le hint
if ($TxtPreviewPlaylistHint) {
    $TxtPreviewPlaylistHint.Add_MouseLeftButtonDown({
        $ChkPlaylist.IsChecked = $true
        $TxtPreviewPlaylistHint.Visibility = 'Collapsed'
    })
}

# ================================================================
#  Dossier destination
# ================================================================
$BtnBrowse.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = $TxtOut.Text
        if ($dlg.ShowDialog() -eq 'OK') {
            $TxtOut.Text = $dlg.SelectedPath
            $c = Read-Config; Set-CfgProp $c 'lastFolder' $dlg.SelectedPath; Save-Config $c
        }
    } catch { Write-Crash 'BtnBrowse' $_ }
})

$BtnOpen.Add_Click({
    if (Test-Path $TxtOut.Text) { Start-Process explorer.exe $TxtOut.Text }
})

# ================================================================
#  Ajout à la file d'attente
# ================================================================
$BtnAddQueue.Add_Click({
    try {
        $raw     = $CmbUrl.Text.Trim()
        $cleaned = Clean-YouTubeUrl $raw
        if (-not $cleaned -or $cleaned -notmatch '^https?://') {
            Show-DarkDialog 'Invalid YouTube URL.' 'Error' '⚠'
            return
        }
        # Évite les doublons en attente
        $already = $queueItems | Where-Object { $_.Url -eq $cleaned -and $_.Status -in @('Queued','Downloading') }
        if ($already) { return }

        $fmt = if ($RdoMp3.IsChecked) { 'MP3' } elseif ($RdoWav.IsChecked) { 'WAV' } else { 'MP4' }
        $item = [QueueItem]::new()
        $item.Url      = $cleaned
        $item.Title    = ''
        $item.Status   = 'Queued'
        $item.Progress = 0
        $item.Format   = $fmt

        # Si la preview est déjà chargée, récupère titre + thumbnail
        if ($TxtPreviewTitle.Text -and $TxtPreviewTitle.Text -ne '') {
            $item.Title     = $TxtPreviewTitle.Text
            $item.Thumbnail = $ImgThumb.Source
        }

        # Capture du nom de fichier custom si l'utilisateur l'a édité et qu'il diffère du titre
        if ($TxtCustomFilename -and $TxtCustomFilename.Text) {
            $customName = Sanitize-Filename $TxtCustomFilename.Text
            $defaultName = Sanitize-Filename $item.Title
            if ($customName -and $customName -ne $defaultName) {
                $item.CustomFilename = $customName
            }
        }

        $queueItems.Add($item)

        # Si pas de titre → fetch titre + thumbnail en background
        if (-not $item.Title) {
            $itemRef   = $item
            $ytdlpPath = $ytdlp
            $urlRef    = $cleaned
            Start-Job -ScriptBlock {
                param($yp, $u)
                try {
                    $json = & $yp --dump-json --no-playlist --no-warnings $u 2>$null | Select-Object -First 1
                    if ($json) {
                        $info = $json | ConvertFrom-Json
                        # Télécharge la thumbnail dans le job (évite blocage UI thread)
                        $thumbBytes = $null
                        if ($info.thumbnail) {
                            try {
                                $wc = New-Object System.Net.WebClient
                                $thumbBytes = $wc.DownloadData($info.thumbnail)
                            } catch {}
                        }
                        return [PSCustomObject]@{ Title = $info.title; ThumbBytes = $thumbBytes }
                    }
                } catch {}
                return $null
            } -ArgumentList $ytdlpPath, $urlRef | ForEach-Object {
                # NOTE : .Add() explicite — `+=` sur une List<T> la remplace par un array,
                # ce qui casse silencieusement Remove() plus tard dans le Tick.
                $script:pendingMetaJobs.Add([PSCustomObject]@{ Job = $_; Item = $itemRef }) | Out-Null
            }
        }
        $TxtQueueEmpty.Visibility = 'Collapsed'
        Save-QueueToConfig
        Update-QueueCounter
        Save-HistoryUrl $cleaned
        # Insert en tête / enlève doublon pour éviter Clear+repopulate (flash visuel + garbage)
        try {
            $existingIdx = $CmbUrl.Items.IndexOf($cleaned)
            if ($existingIdx -ge 0) { $CmbUrl.Items.RemoveAt($existingIdx) }
            $CmbUrl.Items.Insert(0, $cleaned) | Out-Null
            # Trim au maximum historique
            while ($CmbUrl.Items.Count -gt 10) { $CmbUrl.Items.RemoveAt($CmbUrl.Items.Count - 1) }
        } catch {
            # Fallback : rebuild complet
            $CmbUrl.Items.Clear()
            foreach ($h in $historyList) { $CmbUrl.Items.Add($h) | Out-Null }
        }
        $CmbUrl.Text = ''
        $PreviewCard.Visibility = 'Collapsed'
        # Reset du champ filename pour la prochaine URL
        $script:filenameUserEdited = $false
        if ($TxtCustomFilename) {
            $script:suppressFilenameChanged = $true
            try { $TxtCustomFilename.Text = '' } finally { $script:suppressFilenameChanged = $false }
        }
        $script:lastPreviewUrl = ''
    } catch { Write-Crash 'BtnAddQueue' $_ }
})

# Boutons dans la queue (supprimer + relancer + ↑↓)
$LstQueue.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($s, $e)
        if (-not ($e.OriginalSource -is [System.Windows.Controls.Button])) { return }
        $btn  = $e.OriginalSource
        $item = $btn.Tag -as [QueueItem]
        if (-not $item) { return }

        if ($btn.Name -eq 'BtnRemoveItem') {
            if ($item.Status -ne 'Downloading') {
                # Si on retire l'item actuellement en lecture, on arrête proprement le MediaPlayer
                if ($script:currentPlayingItem -and ($script:currentPlayingItem -eq $item)) {
                    try { $script:mediaPlayer.Stop() } catch {}
                    $item.IsPlaying = $false
                    $script:currentPlayingItem = $null
                }
                $queueItems.Remove($item) | Out-Null
                if ($queueItems.Count -eq 0) { $TxtQueueEmpty.Visibility = 'Visible' }
                Save-QueueToConfig
                Update-QueueCounter
            }
        } elseif ($btn.Name -eq 'BtnPlayItem') {
            try {
                # Localise le fichier — priorité au OutputPath stocké à la fin du download
                $filePath = $null
                if ($item.OutputPath -and (Test-Path $item.OutputPath)) {
                    $filePath = $item.OutputPath
                } else {
                    $folder = $TxtOut.Text
                    $nameToSearch = if ($item.CustomFilename) { $item.CustomFilename } else { $item.Title }
                    if ($nameToSearch -and $folder) {
                        $safeName = $nameToSearch -replace '[\\/:*?"<>|]', '_'
                        $extList = if ($item.Format -eq 'MP4') { @('mp4','mkv','webm') } else { @('mp3','wav','m4a','ogg') }
                        foreach ($ext in $extList) {
                            $candidate = Join-Path $folder "$safeName.$ext"
                            if (Test-Path $candidate) { $filePath = $candidate; break }
                        }
                    }
                }

                if ($item.Format -eq 'MP4') {
                    # Vidéo : ouvrir avec l'app par défaut (pas de player intégré pour la vidéo)
                    if ($filePath) {
                        Start-Process $filePath
                    } else {
                        $folder = $TxtOut.Text
                        if (Test-Path $folder) { Start-Process explorer.exe $folder }
                    }
                } else {
                    # Audio : player intégré (play/pause)
                    if ($item.IsPlaying) {
                        $script:mediaPlayer.Pause()
                        $item.IsPlaying = $false
                    } else {
                        if ($script:currentPlayingItem) {
                            $script:mediaPlayer.Stop()
                            $script:currentPlayingItem.IsPlaying = $false
                        }
                        if ($filePath) {
                            $script:mediaPlayer.Open([Uri]::new($filePath))
                            $script:mediaPlayer.Play()
                            $item.IsPlaying = $true
                            $script:currentPlayingItem = $item
                        } else {
                            $folder = $TxtOut.Text
                            if (Test-Path $folder) { Start-Process explorer.exe $folder }
                        }
                    }
                }
            } catch { Write-Crash 'BtnPlayItem' $_ }
        } elseif ($btn.Name -eq 'BtnRetryItem') {
            $item.Status       = 'Queued'
            $item.Progress     = 0
            $item.Speed        = ''
            $item.ErrorMessage = ''
            Update-QueueCounter
        } elseif ($btn.Name -eq 'BtnMoveUp') {
            $idx = $queueItems.IndexOf($item)
            if ($idx -gt 0) { $queueItems.Move($idx, $idx - 1) }
        } elseif ($btn.Name -eq 'BtnMoveDown') {
            $idx = $queueItems.IndexOf($item)
            if ($idx -lt ($queueItems.Count - 1)) { $queueItems.Move($idx, $idx + 1) }
        }
    }
)

# Double-clic sur item Done → ouvrir dans l'explorateur
$LstQueue.Add_MouseDoubleClick({
    param($s, $e)
    try {
        $item = $LstQueue.SelectedItem -as [QueueItem]
        if ($item -and $item.Status -eq 'Done') {
            $folder = $TxtOut.Text
            if (Test-Path $folder) { Start-Process explorer.exe $folder }
        }
    } catch {}
})

$BtnClearDone.Add_Click({
    $done = @($queueItems | Where-Object { $_.Status -in @('Done','Cancelled') -or $_.Status -like 'Failed*' })
    foreach ($d in $done) { $queueItems.Remove($d) | Out-Null }
    if ($queueItems.Count -eq 0) { $TxtQueueEmpty.Visibility = 'Visible' }
    Save-QueueToConfig
    Update-QueueCounter
})

# ================================================================
#  Update yt-dlp bouton
# ================================================================
$BtnUpdateYtdlp.Add_Click({
    $BtnUpdateYtdlp.IsEnabled = $false
    $TxtStatus.Text      = 'Updating yt-dlp...'
    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::Orange
    $ytdlpPath = $ytdlp
    $script:updateYtdlpJob = Start-Job -ScriptBlock {
        param($path)
        try {
            $rel      = Invoke-RestMethod 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -UseBasicParsing -TimeoutSec 20
            $asset    = $rel.assets | Where-Object { $_.name -eq 'yt-dlp.exe' } | Select-Object -First 1
            $sumAsset = $rel.assets | Where-Object { $_.name -eq 'SHA2-256SUMS' } | Select-Object -First 1
            if (-not $asset) { return $null }
            $tmp = $path + '.new'
            Invoke-WebRequest $asset.browser_download_url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
            # Vérification checksum SHA-256 si le fichier de sommes est publié
            if ($sumAsset) {
                try {
                    $sumsText = (Invoke-WebRequest $sumAsset.browser_download_url -UseBasicParsing -TimeoutSec 20).Content
                    $localHash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()
                    $expected = $null
                    foreach ($line in ($sumsText -split "`n")) {
                        if ($line -match '^([0-9a-fA-F]{64})\s+\*?yt-dlp\.exe\s*$') {
                            $expected = $Matches[1].ToLower(); break
                        }
                    }
                    if ($expected -and $expected -ne $localHash) {
                        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                        return $null  # Checksum mismatch → refuse la mise à jour
                    }
                } catch {}
            }
            Move-Item $tmp $path -Force
            return $rel.tag_name
        } catch { return $null }
    } -ArgumentList $ytdlpPath
})

# ================================================================
#  Processus de téléchargement
# ================================================================
$script:proc            = $null
$script:logFile         = $null
$script:logPos          = 0
$script:running         = $false
$script:currentItem     = $null
$script:pendingMetaJobs = [System.Collections.Generic.List[object]]::new()
$script:autoUpdateJob   = $null
$script:confirmed       = $false
$script:cancelling      = $false

function Start-NextDownload {
    $next = $null
    foreach ($it in $queueItems) { if ($it.Status -eq 'Queued') { $next = $it; break } }
    if (-not $next) {
        $script:running = $false
        $BtnCancel.IsEnabled   = $false
        $TxtStatus.Text        = 'All done ✔'
        $TxtStatus.Foreground  = [System.Windows.Media.Brushes]::LightGreen
        Update-GlobalProgress
        # Update-QueueCounter va gérer BtnStartAll.IsEnabled (pending=0 → disabled)
        Update-QueueCounter
        # Toast sans Start-Sleep — on dispose via un DispatcherTimer one-shot
        try {
            [System.Windows.Forms.Application]::EnableVisualStyles()
            $script:toastNotify = New-Object System.Windows.Forms.NotifyIcon
            $script:toastNotify.Icon    = [System.Drawing.SystemIcons]::Information
            $script:toastNotify.Visible = $true
            $script:toastNotify.BalloonTipTitle = 'YouTube Grabber'
            $script:toastNotify.BalloonTipText  = 'All downloads completed!'
            $script:toastNotify.ShowBalloonTip(4000)
            # Dispose après 5 s via timer one-shot
            $script:toastTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:toastTimer.Interval = [TimeSpan]::FromSeconds(5)
            $script:toastTimer.Add_Tick({
                try { $script:toastNotify.Dispose() } catch {}
                $script:toastTimer.Stop()
            })
            $script:toastTimer.Start()
        } catch {}
        return
    }

    $script:currentItem = $next
    $next.Status   = 'Downloading'
    $next.Progress = 0
    $next.Speed    = ''
    Update-GlobalProgress
    Update-QueueCounter
    $out = $TxtOut.Text
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

    $ytArgs = New-Object System.Collections.Generic.List[string]

    if ($next.Format -eq 'MP3') {
        $ytArgs.Add('-x'); $ytArgs.Add('--audio-format'); $ytArgs.Add('mp3')
        $ytArgs.Add('--audio-quality'); $ytArgs.Add('0')
    } elseif ($next.Format -eq 'WAV') {
        $ytArgs.Add('-x'); $ytArgs.Add('--audio-format'); $ytArgs.Add('wav')
    } else {
        $ytArgs.Add('-f'); $ytArgs.Add('bv*+ba/b')
        $ytArgs.Add('--merge-output-format'); $ytArgs.Add('mp4')
    }

    if ($ChkMeta.IsChecked) {
        $ytArgs.Add('--embed-thumbnail')
        $ytArgs.Add('--add-metadata')
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add('%(title)s:%(meta_title)s')
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add('%(uploader)s:%(meta_artist)s')
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add('%(upload_date>%Y)s:%(meta_date)s')
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add(':%(meta_comment)s')
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add(':%(meta_description)s')
    }

    if ($ChkPlaylist.IsChecked) { $ytArgs.Add('--yes-playlist') } else { $ytArgs.Add('--no-playlist') }

    if ($ChkSubs.IsChecked) {
        $ytArgs.Add('--write-subs'); $ytArgs.Add('--write-auto-subs')
        $ytArgs.Add('--sub-langs'); $ytArgs.Add('fr,en')
        $ytArgs.Add('--convert-subs'); $ytArgs.Add('srt')
    }

    $template = if ($ChkPlaylist.IsChecked) {
        # Playlist : on garde le titre par item (le custom filename n'est pas pertinent pour une playlist)
        Join-Path $out '%(playlist_title)s\%(playlist_index)s - %(title)s.%(ext)s'
    } elseif ($next.CustomFilename) {
        # Nom de fichier personnalisé — dédup si un fichier avec le même nom+ext prévue existe déjà
        $baseName = $next.CustomFilename
        $expectedExt = switch ($next.Format) { 'MP3' { 'mp3' } 'WAV' { 'wav' } 'MP4' { 'mp4' } default { '' } }
        if ($expectedExt) {
            $candidate = Join-Path $out "$baseName.$expectedExt"
            $i = 2
            while (Test-Path $candidate) {
                $baseName = "$($next.CustomFilename)-$i"
                $candidate = Join-Path $out "$baseName.$expectedExt"
                $i++
                if ($i -gt 99) { break }  # sanity
            }
            # Refléter dans l'item pour que le play/cleanup retrouvent le bon fichier
            if ($baseName -ne $next.CustomFilename) { $next.CustomFilename = $baseName }
        }
        Join-Path $out ($baseName + '.%(ext)s')
    } else {
        Join-Path $out '%(title)s.%(ext)s'
    }

    $ytArgs.Add('--ffmpeg-location'); $ytArgs.Add((Split-Path -Parent $ffmpeg))
    $ytArgs.Add('-o'); $ytArgs.Add($template)
    $ytArgs.Add('--newline'); $ytArgs.Add('--no-mtime')
    $ytArgs.Add('--encoding'); $ytArgs.Add('utf-8')
    $ytArgs.Add($next.Url)

    $script:logFile = Join-Path $env:TEMP ("ytgrab-" + [Guid]::NewGuid().ToString('N') + ".log")
    $script:logPos  = 0
    New-Item -ItemType File -Path $script:logFile -Force | Out-Null

    # Lancement natif via System.Diagnostics.Process — évite cmd.exe/chcp + tout le quoting fragile
    # d'une command-line concaténée. On construit l'Arguments string en respectant les règles
    # CommandLineToArgvW de Windows (compatible .NET Framework 4.5+).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $ytdlp
    $psi.Arguments              = Build-WindowsCommandLine -ArgList $ytArgs
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.WindowStyle            = 'Hidden'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    # Force UTF-8 côté yt-dlp (Python) sans polluer l'env du parent
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.EnableRaisingEvents = $true
    # Redirection stdout/stderr vers le fichier de log (par event, pour ne pas bloquer)
    $logPath = $script:logFile
    $writeToLog = {
        param($sender, $e)
        if ($e.Data -ne $null) {
            try { [System.IO.File]::AppendAllText($logPath, $e.Data + "`n", [System.Text.Encoding]::UTF8) } catch {}
        }
    }
    $null = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $writeToLog
    $null = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived  -Action $writeToLog

    [void]$p.Start()
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()
    $script:proc    = $p
    $script:running = $true

    $displayTitle = if ($next.Title) { $next.Title } else { $next.Url }
    $short = if ($displayTitle.Length -gt 45) { $displayTitle.Substring(0,45) + '…' } else { $displayTitle }
    $TxtStatus.Text       = "↓ $short"
    # Accent rouge (#F87171 clair pour bonne lisibilité sur fond noir)
    $TxtStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
}

$BtnStartAll.Add_Click({
    if ($script:running) { return }
    # Le bouton est normalement disabled quand rien à télécharger,
    # mais on garde le garde-fou au cas où l'état ne serait pas encore synchronisé.
    $hasPending = $false
    foreach ($it in $queueItems) { if ($it.Status -eq 'Queued') { $hasPending = $true; break } }
    if (-not $hasPending) { return }
    if (-not $ytdlp)  { Show-DarkDialog 'yt-dlp not found.' 'Error' '✕'; return }
    if (-not $ffmpeg) { Show-DarkDialog 'ffmpeg not found.' 'Error' '✕'; return }
    $BtnStartAll.IsEnabled = $false
    $BtnCancel.IsEnabled   = $true
    Start-NextDownload
})

$BtnCancel.Add_Click({
    $script:cancelling = $true
    if ($script:proc -and -not $script:proc.HasExited) {
        # -Wait omis — on ne bloque PAS le thread UI
        Start-Process 'taskkill' -ArgumentList @('/F','/T','/PID',$script:proc.Id.ToString()) -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
    if ($script:currentItem) { $script:currentItem.Status = 'Cancelled'; $script:currentItem.Progress = 0 }
    $script:running        = $false
    # BtnStartAll.IsEnabled est synchronisé par Update-QueueCounter (basé sur les Queued restants)
    $BtnCancel.IsEnabled   = $false
    $TxtStatus.Text        = 'Cancelled.'
    $TxtStatus.Foreground  = [System.Windows.Media.Brushes]::Orange
    # Nettoyage fichiers temporaires laissés par yt-dlp
    try {
        $outDir = $TxtOut.Text
        if (Test-Path $outDir) {
            Get-ChildItem $outDir -File -Recurse | Where-Object {
                # .part / .ytdl = fragments download
                # .f\d+ = fragments ffmpeg
                # .webp / .png standalone = thumbnails résiduels (seulement si pas de vidéo/audio associé)
                $_.Extension -in @('.part', '.ytdl') -or
                $_.Name -match '\.f\d{2,4}\.(webm|mp4|m4a|mkv|opus|aac)$' -or
                ($_.Extension -in @('.webp', '.png') -and $_.Name -notmatch '\.(mp3|mp4|wav|m4a|ogg)\.(webp|png)$')
            } | ForEach-Object {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
    Update-GlobalProgress
    Update-QueueCounter
})

# ================================================================
#  DispatcherTimer (remplace WinForms Timer)
# ================================================================
$timer          = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)

$timer.Add_Tick({
    try {
        # --- Lecture log download ---
        # Skip complètement le Test-Path + ouverture File.Open quand pas de download actif
        if ($script:running -and $script:logFile -and (Test-Path $script:logFile)) {
            $fs = $null
            try {
                $fs = [System.IO.File]::Open($script:logFile, 'Open', 'Read', 'ReadWrite')
                if ($fs.Length -gt $script:logPos) {
                    $fs.Position = $script:logPos
                    $rdr   = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                    $chunk = $rdr.ReadToEnd()
                    $script:logPos = $fs.Position
                    if ($chunk -and $script:currentItem) {
                        # Parsing progression : "[download]  72.3% of ..."
                        # RightToLeft = trouve directement le dernier match sans scanner toutes les occurrences
                        $mLast = [regex]::Match($chunk, '\[download\]\s+(\d+(?:\.\d+)?)%', [System.Text.RegularExpressions.RegexOptions]::RightToLeft)
                        if ($mLast.Success) {
                            $pct = [int][double]$mLast.Groups[1].Value
                            $script:currentItem.Progress = [Math]::Max(0,[Math]::Min(100,$pct))
                        }
                        # Parsing vitesse : "at 1.23MiB/s" ou "at 456.78KiB/s" — dernière occurrence
                        $sv = [regex]::Match($chunk, 'at\s+([\d.]+\s*(?:KiB|MiB|GiB|KB|MB|GB)/s)', [System.Text.RegularExpressions.RegexOptions]::RightToLeft)
                        # Parsing ETA : "ETA 00:42" ou "ETA 01:23:45"
                        $eta = [regex]::Match($chunk, 'ETA\s+(\d+(?::\d+){1,2})', [System.Text.RegularExpressions.RegexOptions]::RightToLeft)
                        if ($sv.Success) {
                            $speedStr = $sv.Groups[1].Value
                            if ($eta.Success) { $speedStr = "$speedStr · $($eta.Groups[1].Value)" }
                            $script:currentItem.Speed = $speedStr
                        } elseif ($eta.Success) {
                            $script:currentItem.Speed = $eta.Groups[1].Value
                        }
                        # Phase post-traitement ffmpeg → 100%
                        if ($chunk -match 'Deleting original|has already been downloaded') {
                            $script:currentItem.Progress = 100
                            $script:currentItem.Speed    = ''
                        }
                    }
                }
            } finally { if ($fs) { $fs.Dispose() } }
        }

        # --- Process terminé ---
        if ($script:proc -and $script:proc.HasExited -and ($script:running -or $script:cancelling)) {
            $exit         = $script:proc.ExitCode
            $wasCancelled = $script:cancelling
            if ($script:currentItem) {
                if ($wasCancelled) {
                    # Annulation explicite — statut "Cancelled" déjà posé par BtnCancel
                    $script:currentItem.Speed = ''
                } elseif ($exit -eq 0) {
                    $script:currentItem.Status   = 'Done'
                    $script:currentItem.Progress = 100
                    $script:currentItem.Speed    = ''

                    # Capture le chemin final du fichier téléchargé (pour ouvrir/lire l'item plus tard,
                    # même si l'utilisateur change de dossier de destination)
                    try {
                        $outDirTmp = $TxtOut.Text
                        $nameForOut = if ($script:currentItem.CustomFilename) { $script:currentItem.CustomFilename } else { $script:currentItem.Title }
                        if ($nameForOut -and (Test-Path $outDirTmp)) {
                            $safeOut = $nameForOut -replace '[\\/:*?"<>|]', '_'
                            $extList = if ($script:currentItem.Format -eq 'MP4') { @('mp4','mkv','webm') } else { @('mp3','wav','m4a','ogg') }
                            foreach ($ext in $extList) {
                                $candidate = Join-Path $outDirTmp "$safeOut.$ext"
                                if (Test-Path $candidate) { $script:currentItem.OutputPath = $candidate; break }
                            }
                        }
                    } catch {}

                    # Cleanup thumbnails résiduels pour ce téléchargement
                    # (garde-fou : ne matche que les fichiers modifiés récemment ET dont le nom = safeName exact,
                    # pour éviter de supprimer les thumbnails d'un autre item qui commencerait par la même chaîne)
                    try {
                        $outDir = $TxtOut.Text
                        $nameForCleanup = if ($script:currentItem.CustomFilename) { $script:currentItem.CustomFilename } else { $script:currentItem.Title }
                        if ($nameForCleanup -and (Test-Path $outDir)) {
                            $safeName = $nameForCleanup -replace '[\\/:*?"<>|]', '_'
                            $sinceUtc = (Get-Date).AddMinutes(-30)  # thumbnail créé pendant ce download
                            Get-ChildItem $outDir -File -ErrorAction SilentlyContinue | Where-Object {
                                # Match exact du basename (pas $safeName*), extension image, mtime récent
                                [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $safeName -and
                                $_.Extension -in @('.webp', '.png') -and
                                $_.LastWriteTime -gt $sinceUtc -and
                                $_.Name -notmatch '\.(mp3|mp4|wav|m4a|ogg)\.(webp|png)$'
                            } | ForEach-Object {
                                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                            }
                        }
                    } catch {}
                } else {
                    # Extrait un message d'erreur intelligible depuis les dernières lignes du log
                    $logTail = ''
                    if ($script:logFile -and (Test-Path $script:logFile)) {
                        try {
                            $allLines = Get-Content $script:logFile -Tail 40 -ErrorAction SilentlyContinue -Encoding UTF8
                            if ($allLines) { $logTail = ($allLines -join "`n") }
                        } catch {}
                    }
                    $script:currentItem.Status       = "Failed"
                    $script:currentItem.Speed        = ''
                    $script:currentItem.ErrorMessage = (Parse-YtDlpError $logTail)
                }
            }
            $script:running     = $false
            $script:cancelling  = $false
            $script:currentItem = $null
            # Cleanup process + event subscribers (évite les zombies quand on lance plusieurs downloads)
            if ($script:proc) {
                try {
                    $script:proc.CancelOutputRead() | Out-Null
                    $script:proc.CancelErrorRead()  | Out-Null
                } catch {}
                # Retire les Register-ObjectEvent liés à ce process
                try {
                    Get-EventSubscriber | Where-Object { $_.SourceObject -eq $script:proc } | ForEach-Object {
                        Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue
                        Remove-Job -Id $_.Action.Id -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
                try { $script:proc.Dispose() } catch {}
                $script:proc = $null
            }
            if ($script:logFile) { try { Remove-Item $script:logFile -Force -ErrorAction SilentlyContinue } catch {}; $script:logFile = $null }
            Save-QueueToConfig
            Update-GlobalProgress
            Update-QueueCounter
            if (-not $wasCancelled) { Start-NextDownload }
        }

        # --- Meta jobs (fetch titre + thumbnail pour items ajoutés sans preview) ---
        if ($script:pendingMetaJobs.Count -gt 0) {
            $done = @($script:pendingMetaJobs | Where-Object { $_.Job.State -in @('Completed','Failed') })
            foreach ($entry in $done) {
                try {
                    $info = Receive-Job $entry.Job -ErrorAction SilentlyContinue
                    if ($info -and $entry.Item) {
                        if ($info.Title) { $entry.Item.Title = $info.Title }
                        if ($info.ThumbBytes) {
                            try {
                                $ms3   = New-Object System.IO.MemoryStream (,$info.ThumbBytes)
                                $bmp2  = New-Object System.Windows.Media.Imaging.BitmapImage
                                $bmp2.BeginInit()
                                $bmp2.StreamSource = $ms3
                                $bmp2.CacheOption  = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                                $bmp2.EndInit()
                                $bmp2.Freeze()
                                $entry.Item.Thumbnail = $bmp2
                            } catch {}
                        }
                    }
                } catch {}
                try { Remove-Job $entry.Job -Force -ErrorAction SilentlyContinue } catch {}
                $script:pendingMetaJobs.Remove($entry) | Out-Null
            }
        }

        # --- Preview job ---
        if ($script:previewJob -and $script:previewJob.State -in @('Completed','Failed')) {
            try {
                $info = Receive-Job $script:previewJob -ErrorAction SilentlyContinue
                if ($info) {
                    $TxtPreviewLoading.Visibility = 'Collapsed'
                    $TxtPreviewTitle.Text = if ($info.title) { $info.title } else { '' }
                    # Pré-remplit le champ nom de fichier avec le titre (si l'utilisateur ne l'a pas déjà édité)
                    if ($TxtCustomFilename -and -not $script:filenameUserEdited -and $info.title) {
                        $script:suppressFilenameChanged = $true
                        try { $TxtCustomFilename.Text = (Sanitize-Filename $info.title) } finally { $script:suppressFilenameChanged = $false }
                    }
                    # artist > creator > uploader
                    $previewArtist = if ($info.artist)   { $info.artist }
                                     elseif ($info.creator) { $info.creator }
                                     else { $info.uploader }
                    $TxtPreviewChannel.Text = if ($previewArtist) { $previewArtist } else { '' }
                    $dur = ''
                    if ($info.duration) {
                        # yt-dlp renvoie parfois duration en int, parfois en float, parfois en string
                        $durSec = 0
                        try { $durSec = [int][double]([string]$info.duration) } catch { $durSec = 0 }
                        if ($durSec -gt 0) {
                            $ts = [TimeSpan]::FromSeconds($durSec)
                            if ($ts.Hours -gt 0) { $dur = "{0}:{1:D2}:{2:D2}" -f $ts.Hours,$ts.Minutes,$ts.Seconds }
                            else                 { $dur = "{0}:{1:D2}" -f $ts.Minutes,$ts.Seconds }
                        }
                    }
                    $TxtPreviewDuration.Text = $dur
                    # Thumbnail : les bytes ont été téléchargés dans le job (plus de blocage UI thread)
                    if ($info.thumbBytes) {
                        try {
                            $ms2   = New-Object System.IO.MemoryStream (,$info.thumbBytes)
                            $bmp   = New-Object System.Windows.Media.Imaging.BitmapImage
                            $bmp.BeginInit()
                            $bmp.StreamSource = $ms2
                            $bmp.CacheOption  = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                            $bmp.EndInit()
                            $bmp.Freeze()
                            $ImgThumb.Source = $bmp
                        } catch {}
                    }
                } else {
                    $PreviewCard.Visibility = 'Collapsed'
                }
            } catch {}
            Remove-Job $script:previewJob -Force -ErrorAction SilentlyContinue
            $script:previewJob = $null
        }

        # --- App update job ---
        if ($script:updateJob -and $script:updateJob.State -in @('Completed','Failed')) {
            try {
                $res = Receive-Job $script:updateJob -ErrorAction SilentlyContinue
                if ($res -and (Compare-Version $res.Tag $AppVersion) -gt 0) {
                    $script:updateAvail        = $res
                    $TxtUpdateBadge.Text       = "⬆ $($res.Tag) available"
                    $TxtUpdateBadge.Visibility = 'Visible'
                }
            } catch {}
            Remove-Job $script:updateJob -Force -ErrorAction SilentlyContinue
            $script:updateJob = $null
        }

        # --- yt-dlp version job ---
        if ($script:ytdlpVerJob -and $script:ytdlpVerJob.State -in @('Completed','Failed')) {
            try {
                $latestYtdlp = Receive-Job $script:ytdlpVerJob -ErrorAction SilentlyContinue
                if ($latestYtdlp) {
                    # Version locale
                    $localVer = ''
                    if ($ytdlp) {
                        try { $localVer = (& $ytdlp --version 2>$null).Trim() } catch {}
                    }
                    $TxtYtdlpVer.Text = "yt-dlp $localVer"
                    if ($localVer -and $latestYtdlp -and $localVer -ne $latestYtdlp) {
                        $TxtYtdlpVer.Text       = "yt-dlp $localVer (latest: $latestYtdlp)"
                        $TxtYtdlpVer.Foreground = [System.Windows.Media.Brushes]::Orange
                        $BtnUpdateYtdlp.Visibility = 'Visible'
                    } else {
                        $TxtYtdlpVer.Foreground = [System.Windows.Media.Brushes]::DimGray
                    }
                }
            } catch {}
            Remove-Job $script:ytdlpVerJob -Force -ErrorAction SilentlyContinue
            $script:ytdlpVerJob = $null
        }

        # --- Update yt-dlp job ---
        if ($script:updateYtdlpJob -and $script:updateYtdlpJob.State -in @('Completed','Failed')) {
            try {
                $newVer = Receive-Job $script:updateYtdlpJob -ErrorAction SilentlyContinue
                if ($newVer) {
                    $TxtStatus.Text       = "yt-dlp updated to $newVer  ✔"
                    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
                    $TxtYtdlpVer.Text     = "yt-dlp $newVer"
                    $BtnUpdateYtdlp.Visibility = 'Collapsed'
                } else {
                    $TxtStatus.Text       = "yt-dlp update failed"
                    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::Tomato
                }
            } catch {}
            Remove-Job $script:updateYtdlpJob -Force -ErrorAction SilentlyContinue
            $script:updateYtdlpJob  = $null
            $BtnUpdateYtdlp.IsEnabled = $true
        }

        # --- Auto-update download job ---
        if ($script:autoUpdateJob -and $script:autoUpdateJob.State -in @('Completed','Failed')) {
            try {
                $setupPath = Receive-Job $script:autoUpdateJob -ErrorAction SilentlyContinue
                if ($setupPath -and (Test-Path $setupPath)) {
                    # Lance l'installer et ferme l'app
                    Start-Process $setupPath
                    $window.Close()
                } else {
                    $TxtUpdateBadge.Text = '⬆ Download failed'
                    $TxtUpdateBadge.Foreground = [System.Windows.Media.Brushes]::Tomato
                }
            } catch {}
            Remove-Job $script:autoUpdateJob -Force -ErrorAction SilentlyContinue
            $script:autoUpdateJob = $null
        }

    } catch { Write-Crash 'DispatcherTimer.Tick' $_ }
})

$timer.Start()

# ================================================================
#  Statut initial (outils)
# ================================================================
if ($ytdlp -and $ffmpeg) {
    $TxtStatus.Text       = 'Ready'
    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
} else {
    $TxtStatus.Text       = 'yt-dlp or ffmpeg not found'
    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::Tomato
}

# ================================================================
#  Lancement
# ================================================================
try {
    $window.ShowDialog() | Out-Null
} catch {
    Write-Crash 'ShowDialog' $_
}

$timer.Stop()

# Sauver la taille/position de la fenêtre (seulement si Normal, pas Minimized/Maximized)
try {
    if ($window.WindowState -eq [System.Windows.WindowState]::Normal) {
        $c = Read-Config
        Set-CfgProp $c 'winWidth'  ([int]$window.ActualWidth)
        Set-CfgProp $c 'winHeight' ([int]$window.ActualHeight)
        Set-CfgProp $c 'winLeft'   ([int]$window.Left)
        Set-CfgProp $c 'winTop'    ([int]$window.Top)
        Save-Config $c
    }
} catch {}

# Flush immédiat à la fermeture (pas de throttle) — force l'écriture avant de quitter
if ($script:queueSaveTimer) { $script:queueSaveTimer.Stop() }
Save-QueueToConfig-Now

# Nettoyage jobs et event subscribers
foreach ($j in @($script:updateJob,$script:ytdlpVerJob,$script:previewJob,$script:updateYtdlpJob,$script:autoUpdateJob)) {
    if ($j) { try { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue } catch {} }
}
# Jobs meta encore en vol
if ($script:pendingMetaJobs) {
    foreach ($entry in @($script:pendingMetaJobs)) {
        try { Stop-Job $entry.Job -ErrorAction SilentlyContinue; Remove-Job $entry.Job -Force -ErrorAction SilentlyContinue } catch {}
    }
}
# Event subscribers (OutputDataReceived / ErrorDataReceived du process yt-dlp)
try { Get-EventSubscriber -ErrorAction SilentlyContinue | ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue } } catch {}
# Kill process yt-dlp éventuellement encore vivant
if ($script:proc -and -not $script:proc.HasExited) {
    try { $script:proc.Kill() } catch {}
    try { $script:proc.Dispose() } catch {}
}
# Toast icon (NotifyIcon) — évite qu'il reste dans la barre des tâches
if ($script:toastNotify) { try { $script:toastNotify.Dispose() } catch {} }
if ($script:logFile -and (Test-Path $script:logFile)) {
    try { Remove-Item $script:logFile -Force -ErrorAction SilentlyContinue } catch {}
}
