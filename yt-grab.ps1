[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ================================================================
#  App metadata
# ================================================================
$AppName    = 'YouTube Grabber by n3lio'
$AppVersion = '2.1.0'
$AppAuthor  = 'n3lio'
$AppRepo    = 'https://github.com/n3lio/yt-grab'

# scriptDir — robuste en mode exe PS2EXE
$scriptDir = $null
try { if ($MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } } catch {}
if (-not $scriptDir) { try { $scriptDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {} }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$crashLog   = Join-Path $scriptDir 'ytgrabber-crash.log'
$configFile = Join-Path $scriptDir 'ytgrabber.config.json'

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

    $inApp = Join-Path $scriptDir $ExeName
    if (Test-Path $inApp) { return $inApp }

    $sys = Get-Command $Name -ErrorAction SilentlyContinue
    if ($sys) { return $sys.Source }

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

    # Téléchargement automatique
    $dest = Join-Path $scriptDir $ExeName
    $ok   = $false
    try {
        if ($Name -eq 'yt-dlp') {
            $rel   = Invoke-RestMethod 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -UseBasicParsing -TimeoutSec 20
            $asset = $rel.assets | Where-Object { $_.name -eq 'yt-dlp.exe' } | Select-Object -First 1
            Invoke-WebRequest $asset.browser_download_url -OutFile $dest -UseBasicParsing
            $ok = $true
        } elseif ($Name -eq 'ffmpeg') {
            $zip = Join-Path $env:TEMP 'ffmpeg-dl.zip'
            $ext = Join-Path $env:TEMP 'ffmpeg-ext'
            Invoke-WebRequest 'https://github.com/GyanD/codexffmpeg/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip' -OutFile $zip -UseBasicParsing
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
#  Update yt-dlp
# ================================================================
function Update-YtDlp {
    param([string]$YtDlpPath)
    try {
        $rel     = Invoke-RestMethod 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -UseBasicParsing -TimeoutSec 15
        $asset   = $rel.assets | Where-Object { $_.name -eq 'yt-dlp.exe' } | Select-Object -First 1
        $tmpDest = $YtDlpPath + '.new'
        Invoke-WebRequest $asset.browser_download_url -OutFile $tmpDest -UseBasicParsing
        Move-Item $tmpDest $YtDlpPath -Force
        return $rel.tag_name
    } catch { Write-Crash 'Update-YtDlp' $_; return $null }
}

# ================================================================
#  Helpers
# ================================================================
function Quote-Arg {
    param([string]$A)
    if ($A -match '[\s"&|<>^()%]') { return '"' + ($A -replace '"','\"') + '"' }
    return $A
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

function Compare-Version {
    param([string]$Va, [string]$Vb)
    $a = $Va.TrimStart('v').Split('.') | ForEach-Object { try { [int]$_ } catch { 0 } }
    $b = $Vb.TrimStart('v').Split('.') | ForEach-Object { try { [int]$_ } catch { 0 } }
    $len = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $na = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $nb = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($na -lt $nb) { return -1 }; if ($na -gt $nb) { return 1 }
    }
    return 0
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
$ytdlpInApp   = Join-Path $scriptDir 'yt-dlp.exe'
$ffmpegInApp  = Join-Path $scriptDir 'ffmpeg.exe'

$script:splashWin = $null

if ((-not (Test-Path $ytdlpInApp)) -or (-not (Test-Path $ffmpegInApp))) {
    $splashXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="YouTube Grabber" Height="190" Width="460"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        WindowStyle="None" Background="#12121A" AllowsTransparency="True">
  <Border CornerRadius="12" Background="#12121A" BorderBrush="#3434A0" BorderThickness="1">
    <StackPanel VerticalAlignment="Center" Margin="32,24">
      <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
        <Border Width="28" Height="28" CornerRadius="6" Background="#FF0000" Margin="0,0,10,0">
          <Path Data="M 0,0 L 0,11 L 10,5.5 Z" Fill="White" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="2,0,0,0"/>
        </Border>
        <TextBlock Text="YouTube Grabber" Foreground="#E8E8F0" FontFamily="Segoe UI" FontSize="16" FontWeight="Bold" VerticalAlignment="Center"/>
      </StackPanel>
      <TextBlock x:Name="SplashMsg" Text="Premier lancement — téléchargement des outils..." Foreground="#9090B0" FontFamily="Segoe UI" FontSize="11" Margin="0,12,0,14"/>
      <ProgressBar x:Name="SplashPrg" IsIndeterminate="True" Height="5" Background="#1E1E2E" Foreground="#6366F1">
        <ProgressBar.Template>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="3" Background="{TemplateBinding Background}" ClipToBounds="True">
              <Border x:Name="PART_Indicator" CornerRadius="3" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}"/>
            </Border>
          </ControlTemplate>
        </ProgressBar.Template>
      </ProgressBar>
      <Button x:Name="SplashClose" Content="Fermer" Margin="0,16,0,0"
              HorizontalAlignment="Right" Width="90" Height="30" Visibility="Collapsed">
        <Button.Template>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="7" Background="#6366F1" Padding="14,0">
              <TextBlock Text="Fermer" Foreground="White" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#818CF8"/>
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
    $script:splashWin.Show()
    $script:splashWin.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

$ytdlp  = Ensure-Tool -Name 'yt-dlp'  -ExeName 'yt-dlp.exe'
$ffmpeg = Ensure-Tool -Name 'ffmpeg'  -ExeName 'ffmpeg.exe'

if ($script:splashWin) {
    try {
        $splashMsg   = $script:splashWin.FindName('SplashMsg')
        $splashPrg   = $script:splashWin.FindName('SplashPrg')
        $splashClose = $script:splashWin.FindName('SplashClose')
        if ($ytdlp -and $ffmpeg) {
            $splashMsg.Text              = 'Outils téléchargés avec succès ✔'
            $splashMsg.Foreground        = [Windows.Media.Brushes]::LightGreen
            $splashPrg.IsIndeterminate   = $false
            $splashPrg.Value             = 100
            $splashPrg.Foreground        = [Windows.Media.Brushes]::LightGreen
        } else {
            $splashMsg.Text              = "Erreur : impossible de télécharger les outils. Vérifie ta connexion."
            $splashMsg.Foreground        = [Windows.Media.Brushes]::Tomato
            $splashPrg.IsIndeterminate   = $false
            $splashPrg.Foreground        = [Windows.Media.Brushes]::Tomato
        }
        $splashClose.Visibility = 'Visible'
        $splashClose.Add_Click({ $script:splashWin.Close() })
        # Pas de fermeture auto — l'utilisateur clique Fermer
    } catch { try { $script:splashWin.Close() } catch {} }
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
    private string _status;
    private int    _progress;
    private string _format;
    private object _thumbnail;
    private string _speed;
    private int    _sortOrder;

    public string Url       { get { return _url; }       set { _url = value;       OnChanged("Url"); } }
    public string Title     { get { return _title; }     set { _title = value;     OnChanged("Title"); OnChanged("DisplayTitle"); } }
    public string Status    { get { return _status; }    set { _status = value;    OnChanged("Status"); OnChanged("RetryVisible"); OnChanged("StatusColor"); } }
    public int    Progress  { get { return _progress; }  set { _progress = value;  OnChanged("Progress"); } }
    public string Format    { get { return _format; }    set { _format = value;    OnChanged("Format"); } }
    public object Thumbnail { get { return _thumbnail; } set { _thumbnail = value; OnChanged("Thumbnail"); } }
    public string Speed     { get { return _speed; }     set { _speed = value;     OnChanged("Speed"); } }
    public int    SortOrder { get { return _sortOrder; } set { _sortOrder = value; OnChanged("SortOrder"); } }

    public string DisplayTitle {
        get {
            if (!string.IsNullOrEmpty(_title)) return _title;
            return _url;
        }
    }

    public string RetryVisible {
        get { return (_status == "Annulé" || (_status != null && _status.StartsWith("Echec"))) ? "Visible" : "Collapsed"; }
    }

    public string StatusColor {
        get {
            if (_status == "Terminé")  return "#3FB950";
            if (_status == "En cours") return "#6366F1";
            if (_status == "Annulé")   return "#E59700";
            if (_status != null && _status.StartsWith("Echec")) return "#F85149";
            return "#6B6B8A";
        }
    }

    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnChanged(string n) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(n)); }
}
'@

$queueItems = New-Object System.Collections.ObjectModel.ObservableCollection[QueueItem]

# Reprise après crash : recharge les items depuis le config et remet "En cours" → "En attente"
function Load-QueueFromConfig {
    $c = Read-Config
    $saved = Get-CfgProp $c 'queue' @()
    foreach ($s in $saved) {
        if (-not $s.Url) { continue }
        $item = [QueueItem]::new()
        $item.Url    = $s.Url
        $item.Title  = if ($s.Title)  { $s.Title }  else { '' }
        $item.Format = if ($s.Format) { $s.Format } else { 'MP3' }
        # "En cours" au moment du crash → reprendre
        $item.Status   = if ($s.Status -eq 'En cours') { 'En attente' } else { $s.Status }
        $item.Progress = if ($s.Status -eq 'Terminé')  { 100 }          else { 0 }
        $queueItems.Add($item)
    }
}

function Save-QueueToConfig {
    $c = Read-Config
    $arr = @($queueItems | ForEach-Object {
        [PSCustomObject]@{ Url=$_.Url; Title=$_.Title; Format=$_.Format; Status=$_.Status }
    })
    Set-CfgProp $c 'queue' $arr
    Save-Config $c
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
    Background="#0E0E16"
    FontFamily="Segoe UI"
    WindowStyle="None"
    AllowsTransparency="True"
    ResizeMode="CanResizeWithGrip"
    AllowDrop="True">

  <Window.Resources>
    <!-- Couleurs globales -->
    <SolidColorBrush x:Key="BrBg"        Color="#0E0E16"/>
    <SolidColorBrush x:Key="BrSurface"   Color="#1A1A28"/>
    <SolidColorBrush x:Key="BrCard"      Color="#1E1E30"/>
    <SolidColorBrush x:Key="BrBorder"    Color="#2E2E4A"/>
    <SolidColorBrush x:Key="BrAccent"    Color="#6366F1"/>
    <SolidColorBrush x:Key="BrAccentHov" Color="#818CF8"/>
    <SolidColorBrush x:Key="BrText"      Color="#E8E8F0"/>
    <SolidColorBrush x:Key="BrMuted"     Color="#6B6B8A"/>
    <SolidColorBrush x:Key="BrOk"        Color="#3FB950"/>
    <SolidColorBrush x:Key="BrDanger"    Color="#F85149"/>
    <SolidColorBrush x:Key="BrWarn"      Color="#E59700"/>

    <!-- Style bouton principal (accent) -->
    <Style x:Key="BtnPrimary" TargetType="Button">
      <Setter Property="Background"   Value="#6366F1"/>
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
                <Setter TargetName="bd" Property="Background" Value="#818CF8"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#4F52D4"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#2E2E4A"/>
                <Setter TargetName="bd" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Style bouton secondaire -->
    <Style x:Key="BtnSecondary" TargetType="Button">
      <Setter Property="Background"      Value="#1E1E30"/>
      <Setter Property="Foreground"      Value="#C0C0D8"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="Padding"         Value="14,0"/>
      <Setter Property="Height"          Value="34"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush"     Value="#2E2E4A"/>
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
                <Setter TargetName="bd" Property="Background" Value="#28283E"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#4A4A6A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#14141E"/>
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
      <Setter Property="Background"      Value="#1E1E30"/>
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
      <Setter Property="Background"      Value="#1E1E30"/>
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
      <Setter Property="Background"            Value="#1E1E30"/>
      <Setter Property="Foreground"            Value="#E8E8F0"/>
      <Setter Property="CaretBrush"            Value="#6366F1"/>
      <Setter Property="BorderBrush"           Value="#2E2E4A"/>
      <Setter Property="BorderThickness"       Value="1"/>
      <Setter Property="Padding"               Value="10,0"/>
      <Setter Property="FontSize"              Value="12"/>
      <Setter Property="SelectionBrush"        Value="#6366F1"/>
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
                <Setter TargetName="bd" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ComboBox dark — template complet pour harmoniser fond/bords/dropdown -->
    <Style x:Key="CmbDark" TargetType="ComboBox">
      <Setter Property="Background"      Value="#1E1E30"/>
      <Setter Property="Foreground"      Value="#E8E8F0"/>
      <Setter Property="BorderBrush"     Value="#2E2E4A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="ItemContainerStyle">
        <Setter.Value>
          <Style TargetType="ComboBoxItem">
            <Setter Property="Background"  Value="#1E1E30"/>
            <Setter Property="Foreground"  Value="#E8E8F0"/>
            <Setter Property="FontSize"    Value="12"/>
            <Setter Property="Padding"     Value="10,6"/>
            <Style.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#28283E"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Background" Value="#2E2E50"/>
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
                         CaretBrush="#6366F1" SelectionBrush="#6366F1"
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
                              Fill="#6B6B8A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                          <Setter TargetName="arrow" Property="Fill" Value="#9090B0"/>
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
                  <Border CornerRadius="7" Background="#1E1E30" BorderBrush="#2E2E4A" BorderThickness="1"
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
                <Setter TargetName="bd" Property="BorderBrush" Value="#6366F1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ProgressBar dark -->
    <Style x:Key="PrgDark" TargetType="ProgressBar">
      <Setter Property="Background" Value="#1E1E30"/>
      <Setter Property="Foreground" Value="#6366F1"/>
      <Setter Property="Height"     Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="3" Background="{TemplateBinding Background}" ClipToBounds="True">
              <Border x:Name="PART_Indicator" CornerRadius="3" HorizontalAlignment="Left"
                      Background="{TemplateBinding Foreground}"/>
            </Border>
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
      <Setter Property="Foreground" Value="#C0C0D8"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="Margin"     Value="0,0,18,0"/>
      <Setter Property="Cursor"     Value="Hand"/>
    </Style>

    <!-- CheckBox dark -->
    <Style x:Key="ChkDark" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C0C0D8"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="Margin"     Value="0,0,18,0"/>
      <Setter Property="Cursor"     Value="Hand"/>
    </Style>
  </Window.Resources>

  <!-- Fenêtre avec bord arrondi et drag -->
  <Border CornerRadius="12" Background="#0E0E16" BorderBrush="#2E2E4A" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="42"/>   <!-- title bar -->
        <RowDefinition Height="*"/>    <!-- contenu -->
      </Grid.RowDefinitions>

      <!-- ===== TITLE BAR ===== -->
      <Border Grid.Row="0" CornerRadius="12,12,0,0" Background="#12121E" x:Name="TitleBar">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <!-- Barre de progression globale en fond de la title bar -->
          <ProgressBar x:Name="PrgGlobal" Grid.ColumnSpan="2" Value="0" Maximum="100"
                       Height="42" VerticalAlignment="Stretch" HorizontalAlignment="Stretch"
                       Opacity="0.07" Background="Transparent" Foreground="#6366F1" BorderThickness="0">
            <ProgressBar.Template>
              <ControlTemplate TargetType="ProgressBar">
                <Border CornerRadius="12,12,0,0" Background="Transparent" ClipToBounds="True">
                  <Border x:Name="PART_Indicator" CornerRadius="12,0,0,0" HorizontalAlignment="Left"
                          Background="#6366F1"/>
                </Border>
              </ControlTemplate>
            </ProgressBar.Template>
          </ProgressBar>
          <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0">
            <Ellipse Width="10" Height="10" Fill="#6366F1" Margin="0,0,8,0"/>
            <TextBlock Text="YouTube Grabber" Foreground="#E8E8F0" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtVersion" Text="" Foreground="#8888AA" FontSize="11" VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtGlobalProgress" Text="" Foreground="#6B6BAA" FontSize="10"
                       VerticalAlignment="Center" Margin="10,0,0,0" Visibility="Collapsed"/>
            <TextBlock x:Name="TxtYtdlpVer" Text="" Foreground="#555570" FontSize="10" VerticalAlignment="Center" Margin="10,0,0,0"/>
            <TextBlock x:Name="TxtUpdateBadge" Text="" Foreground="#E59700" FontSize="11"
                       VerticalAlignment="Center" Margin="10,0,0,0" Cursor="Hand"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0">
            <Button x:Name="BtnAbout"    Width="28" Height="28" Margin="0,0,6,0" Cursor="Hand"
                    Background="#1E1E30" BorderBrush="#2E2E4A" BorderThickness="1" ToolTip="À propos">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                          BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                    <TextBlock Text="?" Foreground="#C0C0D8" FontSize="13" FontWeight="Bold"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="bd" Property="Background" Value="#28283E"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
            </Button>
            <Button x:Name="BtnMinimize" Width="28" Height="28" Margin="0,0,6,0" Cursor="Hand"
                    Background="#1E1E30" BorderBrush="#2E2E4A" BorderThickness="1" ToolTip="Réduire">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                          BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                    <TextBlock Text="─" Foreground="#C0C0D8" FontSize="13"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="bd" Property="Background" Value="#28283E"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
            </Button>
            <Button x:Name="BtnClose"    Width="28" Height="28" Cursor="Hand"
                    Background="#1E1E30" BorderBrush="#F85149" BorderThickness="1" ToolTip="Fermer">
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
          </Grid.ColumnDefinitions>
          <!-- Wrapper avec icône inline à gauche -->
          <Border Grid.Column="0" CornerRadius="7" Background="#1E1E30"
                  BorderBrush="#2E2E4A" BorderThickness="1" Height="38" Margin="0,0,8,0"
                  x:Name="CmbUrlBorder">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="38"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <!-- Icône YouTube (triangle play dans carré arrondi rouge) -->
              <Border Grid.Column="0" Width="22" Height="22" CornerRadius="5" Background="#FF0000"
                      HorizontalAlignment="Center" VerticalAlignment="Center" Margin="8,0,0,0">
                <Path Data="M 0,0 L 0,9 L 8,4.5 Z" Fill="White"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Margin="2,0,0,0"/>
              </Border>
              <!-- ComboBox sans bordure, s'intègre dans le wrapper -->
              <ComboBox x:Name="CmbUrl" Grid.Column="1" Height="36"
                        IsEditable="True" Text="" FontSize="12"
                        Background="Transparent" Foreground="#E8E8F0"
                        BorderThickness="0" VerticalContentAlignment="Center"
                        Style="{StaticResource CmbDark}"/>
            </Grid>
          </Border>
          <Button x:Name="BtnAddQueue" Grid.Column="1" Content="+ Ajouter" Style="{StaticResource BtnPrimary}"
                  Width="100" Height="38"/>
        </Grid>

        <!-- Preview card (masqué par défaut) -->
        <Border Grid.Row="1" x:Name="PreviewCard" CornerRadius="9" Background="#1A1A28"
                BorderBrush="#2E2E4A" BorderThickness="1" Margin="0,0,0,10"
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
              <TextBlock x:Name="TxtPreviewTitle"    Foreground="#E8E8F0" FontSize="12" FontWeight="SemiBold"
                         TextTrimming="CharacterEllipsis" MaxWidth="500"/>
              <TextBlock x:Name="TxtPreviewChannel"  Foreground="#6B6B8A" FontSize="10" Margin="0,3,0,0"/>
              <TextBlock x:Name="TxtPreviewDuration" Foreground="#6B6B8A" FontSize="10" Margin="0,2,0,0"/>
            </StackPanel>
            <TextBlock x:Name="TxtPreviewLoading" Grid.ColumnSpan="2" Text="Chargement preview..."
                       Foreground="#4A4A6A" FontSize="11" VerticalAlignment="Center" HorizontalAlignment="Center"
                       Visibility="Collapsed"/>
          </Grid>
        </Border>

        <!-- Options -->
        <Border Grid.Row="2" CornerRadius="9" Background="#1A1A28" BorderBrush="#2E2E4A" BorderThickness="1"
                Margin="0,0,0,10" Padding="14,10">
          <WrapPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,24,0">
              <TextBlock Text="Format :" Foreground="#9090B0" FontSize="12" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <RadioButton x:Name="RdoMp3" Content="MP3 (320k)" Style="{StaticResource RdoDark}" IsChecked="True" GroupName="fmt"/>
              <RadioButton x:Name="RdoWav" Content="WAV (lossless)" Style="{StaticResource RdoDark}" GroupName="fmt"/>
              <RadioButton x:Name="RdoMp4" Content="MP4 (best)" Style="{StaticResource RdoDark}" GroupName="fmt"/>
            </StackPanel>
            <CheckBox x:Name="ChkPlaylist" Content="Toute la playlist"  Style="{StaticResource ChkDark}"/>
            <CheckBox x:Name="ChkSubs"     Content="Sous-titres (.srt)" Style="{StaticResource ChkDark}"/>
            <CheckBox x:Name="ChkMeta"     Content="Métadonnées + cover" Style="{StaticResource ChkDark}" IsChecked="True"/>
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
          <Border Grid.Column="0" CornerRadius="7" Background="#1E1E30"
                  BorderBrush="#2E2E4A" BorderThickness="1" Height="36" Margin="0,0,8,0"
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
                      Fill="#9090B0"/>
                <Path Data="M 0,3 L 18,3 L 18,5 L 0,5 Z" Fill="#6B6B8A"/>
              </Canvas>
              <TextBox x:Name="TxtOut" Grid.Column="1" Height="34"
                       IsReadOnly="True" Background="Transparent" BorderThickness="0"
                       Foreground="#E8E8F0" FontSize="12" VerticalContentAlignment="Center"
                       Padding="4,0,8,0"/>
            </Grid>
          </Border>
          <Button x:Name="BtnBrowse" Grid.Column="1" Content="Changer" Style="{StaticResource BtnSecondary}"
                  Width="80" Margin="0,0,8,0"/>
          <Button x:Name="BtnOpen"   Grid.Column="2" Content="📂 Ouvrir" Style="{StaticResource BtnSecondary}"
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
          <Button x:Name="BtnStartAll" Grid.Column="0" Content="⬇  Tout télécharger"
                  Style="{StaticResource BtnPrimary}" Width="170" Margin="0,0,8,0"/>
          <Button x:Name="BtnCancel"   Grid.Column="1" Content="✕  Annuler"
                  Style="{StaticResource BtnDanger}"   Width="110" IsEnabled="False" Margin="0,0,8,0"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,0,0">
            <TextBlock x:Name="TxtStatus" Text="Prêt" Foreground="#3FB950" FontSize="12" VerticalAlignment="Center"/>
          </StackPanel>
          <Button x:Name="BtnUpdateYtdlp" Grid.Column="3" Content="↑ yt-dlp"
                  Style="{StaticResource BtnSecondary}" Width="90" Visibility="Collapsed"/>
        </Grid>

        <!-- File d'attente -->
        <Border Grid.Row="5" CornerRadius="9" Background="#1A1A28" BorderBrush="#2E2E4A" BorderThickness="1"
                ClipToBounds="True">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="32"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <!-- Header queue -->
            <Border Grid.Row="0" Background="#14141E" CornerRadius="9,9,0,0" Padding="14,0">
              <Grid>
                <TextBlock x:Name="TxtQueueHeader" Text="File d'attente" Foreground="#9090B0" FontSize="12"
                           FontWeight="SemiBold" VerticalAlignment="Center"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <Button x:Name="BtnClearDone" Content="Effacer terminés"
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
                  <Setter Property="BorderBrush"                Value="#1E1E30"/>
                  <Style.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter Property="Background" Value="#1E1E2C"/>
                    </Trigger>
                    <Trigger Property="IsSelected" Value="True">
                      <Setter Property="Background" Value="#1E1E2C"/>
                    </Trigger>
                  </Style.Triggers>
                </Style>
              </ListView.ItemContainerStyle>
              <ListView.ItemTemplate>
                <DataTemplate>
                  <Grid Margin="10,5" AllowDrop="True" Background="Transparent">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="20"/>   <!-- drag handle + réorder -->
                      <ColumnDefinition Width="44"/>   <!-- thumbnail -->
                      <ColumnDefinition Width="*"/>    <!-- titre + url -->
                      <ColumnDefinition Width="90"/>   <!-- progress -->
                      <ColumnDefinition Width="62"/>   <!-- speed -->
                      <ColumnDefinition Width="62"/>   <!-- status -->
                      <ColumnDefinition Width="26"/>   <!-- retry -->
                      <ColumnDefinition Width="26"/>   <!-- remove -->
                    </Grid.ColumnDefinitions>
                    <!-- Drag handle + boutons réorder -->
                    <StackPanel Grid.Column="0" VerticalAlignment="Center" HorizontalAlignment="Center">
                      <Button Content="▲" Tag="{Binding}" Width="16" Height="14"
                              x:Name="BtnMoveUp" Padding="0" FontSize="7" Margin="0,0,0,1"
                              Cursor="Hand" Background="Transparent" BorderThickness="0" Foreground="#44446A">
                        <Button.Template>
                          <ControlTemplate TargetType="Button">
                            <Border Background="Transparent">
                              <TextBlock Text="▲" Foreground="#44446A" FontSize="7"
                                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="#9090B0"/>
                              </Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Button.Template>
                      </Button>
                      <Button Content="▼" Tag="{Binding}" Width="16" Height="14"
                              x:Name="BtnMoveDown" Padding="0" FontSize="7"
                              Cursor="Hand" Background="Transparent" BorderThickness="0" Foreground="#44446A">
                        <Button.Template>
                          <ControlTemplate TargetType="Button">
                            <Border Background="Transparent">
                              <TextBlock Text="▼" Foreground="#44446A" FontSize="7"
                                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="#9090B0"/>
                              </Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Button.Template>
                      </Button>
                    </StackPanel>
                    <!-- Thumbnail miniature -->
                    <Border Grid.Column="1" CornerRadius="4" ClipToBounds="True"
                            Width="40" Height="26" VerticalAlignment="Center" Margin="2,0,6,0"
                            Background="#14141E">
                      <Image Source="{Binding Thumbnail}" Stretch="UniformToFill"/>
                    </Border>
                    <!-- Titre + URL -->
                    <StackPanel Grid.Column="2" VerticalAlignment="Center">
                      <TextBlock Text="{Binding DisplayTitle}" Foreground="#E8E8F0" FontSize="12"
                                 TextTrimming="CharacterEllipsis"/>
                      <TextBlock Text="{Binding Url}" Foreground="#55557A" FontSize="9"
                                 TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                    <!-- ProgressBar -->
                    <ProgressBar Grid.Column="3" Value="{Binding Progress}" Maximum="100" Minimum="0"
                                 Style="{StaticResource PrgDark}" Height="8" VerticalAlignment="Center" Margin="6,0"/>
                    <!-- Vitesse -->
                    <TextBlock Grid.Column="4" Text="{Binding Speed}" Foreground="#6B6BAA"
                               FontSize="9" VerticalAlignment="Center" HorizontalAlignment="Center"
                               TextAlignment="Center"/>
                    <!-- Status -->
                    <TextBlock Grid.Column="5" Text="{Binding Status}" Foreground="{Binding StatusColor}"
                               FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center" HorizontalAlignment="Center"
                               TextWrapping="Wrap" TextAlignment="Center"/>
                    <!-- Retry -->
                    <Button Grid.Column="6" Content="↺" Tag="{Binding}" Width="22" Height="22"
                            x:Name="BtnRetryItem" Style="{StaticResource BtnOk}" Padding="0" FontSize="12"
                            VerticalAlignment="Center" HorizontalAlignment="Center"
                            Visibility="{Binding RetryVisible}"/>
                    <!-- Remove -->
                    <Button Grid.Column="7" Content="✕" Tag="{Binding}" Width="22" Height="22"
                            x:Name="BtnRemoveItem" Style="{StaticResource BtnDanger}" Padding="0" FontSize="10"
                            VerticalAlignment="Center" HorizontalAlignment="Center"/>
                  </Grid>
                </DataTemplate>
              </ListView.ItemTemplate>
            </ListView>
            <!-- Placeholder queue vide -->
            <TextBlock Grid.Row="1" x:Name="TxtQueueEmpty"
                       Text="Colle une URL ci-dessus et clique + Ajouter"
                       Foreground="#4A4A70" FontSize="12" HorizontalAlignment="Center"
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
$BtnAddQueue     = Find-Ctrl 'BtnAddQueue'
$PreviewCard     = Find-Ctrl 'PreviewCard'
$ImgThumb        = Find-Ctrl 'ImgThumb'
$TxtPreviewTitle  = Find-Ctrl 'TxtPreviewTitle'
$TxtPreviewChannel= Find-Ctrl 'TxtPreviewChannel'
$TxtPreviewDuration=Find-Ctrl 'TxtPreviewDuration'
$TxtPreviewLoading= Find-Ctrl 'TxtPreviewLoading'
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
$BtnClearDone    = Find-Ctrl 'BtnClearDone'
$TxtYtdlpVer     = Find-Ctrl 'TxtYtdlpVer'

# Init valeurs
$TxtVersion.Text = " v$AppVersion"
$TxtOut.Text     = $defaultOut
foreach ($h in $historyList) { $CmbUrl.Items.Add($h) | Out-Null }
$LstQueue.ItemsSource = $queueItems
if ($queueItems.Count -gt 0) {
    $TxtQueueEmpty.Visibility = 'Collapsed'
    Update-GlobalProgress
}

# ================================================================
#  Helper — modale dark (remplace MessageBox.Show)
# ================================================================
function Show-DarkDialog {
    param([string]$Message, [string]$Title='YouTube Grabber', [string]$Icon='ℹ')
    $iconColor = switch ($Icon) {
        '⚠' { '#E59700' }; '✕' { '#F85149' }; '✔' { '#3FB950' }; default { '#6366F1' }
    }
    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" SizeToContent="Height" Width="360"
        WindowStartupLocation="CenterOwner"
        Background="#0E0E16" FontFamily="Segoe UI"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize">
  <Border CornerRadius="12" Background="#0E0E16" BorderBrush="#2E2E4A" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="38"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="52"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" CornerRadius="12,12,0,0" Background="#12121E" x:Name="DlgBar">
        <TextBlock Text="$Title" Foreground="#E8E8F0" FontSize="12" FontWeight="SemiBold"
                   VerticalAlignment="Center" Margin="16,0"/>
      </Border>
      <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="20,16">
        <TextBlock Text="$Icon" Foreground="$iconColor" FontSize="22" VerticalAlignment="Top" Margin="0,0,14,0"/>
        <TextBlock Text="$Message" Foreground="#C8C8E0" FontSize="12" TextWrapping="Wrap"
                   VerticalAlignment="Center" MaxWidth="270"/>
      </StackPanel>
      <Border Grid.Row="2" CornerRadius="0,0,12,12" Background="#12121E">
        <Button x:Name="DlgOk" Width="90" Height="32" HorizontalAlignment="Center" VerticalAlignment="Center">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="bd" CornerRadius="7" Background="#6366F1">
                <TextBlock Text="OK" Foreground="White" FontSize="12" FontWeight="SemiBold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="bd" Property="Background" Value="#818CF8"/>
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
$BtnClose.Add_Click({ $window.Close() })
$BtnMinimize.Add_Click({ $window.WindowState = 'Minimized' })

$BtnAbout.Add_Click({
    try {
        $aboutXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="À propos" Width="400" Height="300"
        WindowStartupLocation="CenterOwner"
        Background="#0E0E16" FontFamily="Segoe UI"
        WindowStyle="None" AllowsTransparency="True"
        ResizeMode="NoResize">
  <Border CornerRadius="12" Background="#0E0E16" BorderBrush="#2E2E4A" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="40"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="60"/>
      </Grid.RowDefinitions>

      <!-- Title bar -->
      <Border Grid.Row="0" CornerRadius="12,12,0,0" Background="#12121E" x:Name="AboutTitleBar">
        <Grid Margin="16,0">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="8" Height="8" Fill="#6366F1" Margin="0,0,8,0"/>
            <TextBlock Text="À propos" Foreground="#E8E8F0" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </StackPanel>
          <Button x:Name="BtnAboutClose" Width="26" Height="26" HorizontalAlignment="Right" VerticalAlignment="Center"
                  Background="#1E1E30" BorderBrush="#F85149" BorderThickness="1" Cursor="Hand">
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
        <Border CornerRadius="16" Background="#1A1A28" BorderBrush="#3434A0" BorderThickness="1"
                Width="64" Height="64" HorizontalAlignment="Center" Margin="0,0,0,16">
          <TextBlock Text="▶" Foreground="#6366F1" FontSize="28" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock Text="YouTube Grabber" Foreground="#E8E8F0" FontSize="18" FontWeight="Bold"
                   HorizontalAlignment="Center"/>
        <TextBlock x:Name="AboutVersion" Foreground="#6366F1" FontSize="12" HorizontalAlignment="Center" Margin="0,4,0,0"/>
        <TextBlock Text="by n3lio" Foreground="#6B6B8A" FontSize="11" HorizontalAlignment="Center" Margin="0,2,0,16"/>
        <TextBlock Text="Powered by yt-dlp + ffmpeg" Foreground="#4A4A6A" FontSize="10"
                   HorizontalAlignment="Center"/>
        <TextBlock x:Name="AboutRepo" Foreground="#3E3EA0" FontSize="10" HorizontalAlignment="Center"
                   Margin="0,4,0,0" Cursor="Hand" TextDecorations="Underline"/>
      </StackPanel>

      <!-- Footer OK button -->
      <Border Grid.Row="2" CornerRadius="0,0,12,12" Background="#12121E">
        <Button x:Name="BtnAboutOk" Content="Fermer" Width="110" Height="34"
                HorizontalAlignment="Center" VerticalAlignment="Center">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="bd" CornerRadius="8" Background="#6366F1" Padding="18,0">
                <TextBlock Text="Fermer" Foreground="White" FontSize="12" FontWeight="SemiBold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="bd" Property="Background" Value="#818CF8"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                  <Setter TargetName="bd" Property="Background" Value="#4F52D4"/>
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
# ================================================================
$window.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return' -and $CmbUrl.IsFocused) {
        $BtnAddQueue.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
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
#  Update badge (cliquable)
# ================================================================
$TxtUpdateBadge.Add_MouseLeftButtonDown({
    if ($script:updateAvail) { Start-Process $script:updateAvail.Url }
})

# ================================================================
#  Détection URL en temps réel → preview + auto-playlist
# ================================================================
$script:previewJob   = $null
$script:lastPreviewUrl = ''

# WPF ComboBox editable : pas de Add_TextChanged direct, on passe par le routed event
$CmbUrl.AddHandler(
    [System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
    [System.Windows.Controls.TextChangedEventHandler]{
        try {
            $raw      = $CmbUrl.Text.Trim()
            $detected = Detect-UrlType $raw
            if ($detected -eq 'playlist')  { $ChkPlaylist.IsChecked = $true }
            elseif ($detected -eq 'video') { $ChkPlaylist.IsChecked = $false }

            $cleaned = Clean-YouTubeUrl $raw
            if ($cleaned -ne $script:lastPreviewUrl -and $cleaned -match '^https?://') {
                $script:lastPreviewUrl = $cleaned
                if ($script:previewJob) {
                    try { Stop-Job $script:previewJob -ErrorAction SilentlyContinue; Remove-Job $script:previewJob -Force -ErrorAction SilentlyContinue } catch {}
                }
                $PreviewCard.Visibility       = 'Visible'
                $TxtPreviewLoading.Visibility = 'Visible'
                $ImgThumb.Source              = $null
                $TxtPreviewTitle.Text         = ''
                $TxtPreviewChannel.Text       = ''
                $TxtPreviewDuration.Text      = ''
                $ytdlpPath = $ytdlp
                $script:previewJob = Start-Job -ScriptBlock {
                    param($ytPath, $url)
                    try {
                        $json = & $ytPath --dump-json --no-playlist --no-warnings $url 2>$null | Select-Object -First 1
                        if ($json) { return $json | ConvertFrom-Json }
                    } catch {}
                    return $null
                } -ArgumentList $ytdlpPath, $cleaned
            } elseif ($cleaned -notmatch '^https?://') {
                $PreviewCard.Visibility = 'Collapsed'
            }
        } catch {}
    }
)

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
            Show-DarkDialog 'URL YouTube invalide.' 'Erreur' '⚠'
            return
        }
        # Évite les doublons en attente
        $already = $queueItems | Where-Object { $_.Url -eq $cleaned -and $_.Status -in @('En attente','En cours') }
        if ($already) { return }

        $fmt = if ($RdoMp3.IsChecked) { 'MP3' } elseif ($RdoWav.IsChecked) { 'WAV' } else { 'MP4' }
        $item = [QueueItem]::new()
        $item.Url      = $cleaned
        $item.Title    = ''
        $item.Status   = 'En attente'
        $item.Progress = 0
        $item.Format   = $fmt

        # Si la preview est déjà chargée, récupère titre + thumbnail
        if ($TxtPreviewTitle.Text -and $TxtPreviewTitle.Text -ne '') {
            $item.Title     = $TxtPreviewTitle.Text
            $item.Thumbnail = $ImgThumb.Source
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
                        return [PSCustomObject]@{ Title = $info.title; Thumb = $info.thumbnail }
                    }
                } catch {}
                return $null
            } -ArgumentList $ytdlpPath, $urlRef | ForEach-Object {
                $script:pendingMetaJobs += [PSCustomObject]@{ Job = $_; Item = $itemRef }
            }
        }
        $TxtQueueEmpty.Visibility = 'Collapsed'
        Save-QueueToConfig
        Save-HistoryUrl $cleaned
        $CmbUrl.Items.Clear()
        foreach ($h in $historyList) { $CmbUrl.Items.Add($h) | Out-Null }
        $CmbUrl.Text = ''
        $PreviewCard.Visibility = 'Collapsed'
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
            if ($item.Status -ne 'En cours') {
                $queueItems.Remove($item) | Out-Null
                if ($queueItems.Count -eq 0) { $TxtQueueEmpty.Visibility = 'Visible' }
                Save-QueueToConfig
            }
        } elseif ($btn.Name -eq 'BtnRetryItem') {
            $item.Status   = 'En attente'
            $item.Progress = 0
            $item.Speed    = ''
        } elseif ($btn.Name -eq 'BtnMoveUp') {
            $idx = $queueItems.IndexOf($item)
            if ($idx -gt 0) { $queueItems.Move($idx, $idx - 1) }
        } elseif ($btn.Name -eq 'BtnMoveDown') {
            $idx = $queueItems.IndexOf($item)
            if ($idx -lt ($queueItems.Count - 1)) { $queueItems.Move($idx, $idx + 1) }
        }
    }
)

# Double-clic sur item Terminé → ouvrir dans l'explorateur
$LstQueue.Add_MouseDoubleClick({
    param($s, $e)
    try {
        $item = $LstQueue.SelectedItem -as [QueueItem]
        if ($item -and $item.Status -eq 'Terminé') {
            $folder = $TxtOut.Text
            if (Test-Path $folder) { Start-Process explorer.exe $folder }
        }
    } catch {}
})

$BtnClearDone.Add_Click({
    $done = @($queueItems | Where-Object { $_.Status -in @('Terminé','Annulé') -or $_.Status -like 'Echec*' })
    foreach ($d in $done) { $queueItems.Remove($d) | Out-Null }
    if ($queueItems.Count -eq 0) { $TxtQueueEmpty.Visibility = 'Visible' }
    Save-QueueToConfig
})

# ================================================================
#  Update yt-dlp bouton
# ================================================================
$BtnUpdateYtdlp.Add_Click({
    $BtnUpdateYtdlp.IsEnabled = $false
    $TxtStatus.Text      = 'Mise a jour yt-dlp...'
    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::Orange
    $ytdlpPath = $ytdlp
    $script:updateYtdlpJob = Start-Job -ScriptBlock {
        param($path)
        try {
            $rel   = Invoke-RestMethod 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -UseBasicParsing -TimeoutSec 20
            $asset = $rel.assets | Where-Object { $_.name -eq 'yt-dlp.exe' } | Select-Object -First 1
            $tmp   = $path + '.new'
            Invoke-WebRequest $asset.browser_download_url -OutFile $tmp -UseBasicParsing
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

function Update-GlobalProgress {
    $total    = $queueItems.Count
    $done     = @($queueItems | Where-Object { $_.Status -eq 'Terminé' }).Count
    $failed   = @($queueItems | Where-Object { $_.Status -like 'Echec*' -or $_.Status -eq 'Annulé' }).Count
    if ($total -gt 0) {
        $pct = [int](($done / $total) * 100)
        $PrgGlobal.Value = $pct
        $TxtGlobalProgress.Text       = "$done/$total"
        $TxtGlobalProgress.Visibility = 'Visible'
    } else {
        $PrgGlobal.Value = 0
        $TxtGlobalProgress.Visibility = 'Collapsed'
    }
}

function Start-NextDownload {
    $next = $queueItems | Where-Object { $_.Status -eq 'En attente' } | Select-Object -First 1
    if (-not $next) {
        $script:running = $false
        $BtnStartAll.IsEnabled = $true
        $BtnCancel.IsEnabled   = $false
        $TxtStatus.Text        = 'Tout terminé ✔'
        $TxtStatus.Foreground  = [System.Windows.Media.Brushes]::LightGreen
        Update-GlobalProgress
        # Toast sans Start-Sleep — on dispose via un DispatcherTimer one-shot
        try {
            [System.Windows.Forms.Application]::EnableVisualStyles()
            $script:toastNotify = New-Object System.Windows.Forms.NotifyIcon
            $script:toastNotify.Icon    = [System.Drawing.SystemIcons]::Information
            $script:toastNotify.Visible = $true
            $script:toastNotify.BalloonTipTitle = 'YouTube Grabber'
            $script:toastNotify.BalloonTipText  = 'Tous les téléchargements sont terminés !'
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
    $next.Status   = 'En cours'
    $next.Progress = 0
    $next.Speed    = ''
    Update-GlobalProgress
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
        Join-Path $out '%(playlist_title)s\%(playlist_index)s - %(title)s.%(ext)s'
    } else {
        Join-Path $out '%(title)s.%(ext)s'
    }

    $ytArgs.Add('--ffmpeg-location'); $ytArgs.Add((Split-Path -Parent $ffmpeg))
    $ytArgs.Add('-o'); $ytArgs.Add($template)
    $ytArgs.Add('--newline'); $ytArgs.Add('--no-mtime')
    $ytArgs.Add('--encoding'); $ytArgs.Add('utf-8')
    $ytArgs.Add($next.Url)

    $argString = ($ytArgs | ForEach-Object { Quote-Arg $_ }) -join ' '

    $script:logFile = Join-Path $env:TEMP ("ytgrab-" + [Guid]::NewGuid().ToString('N') + ".log")
    $script:logPos  = 0
    New-Item -ItemType File -Path $script:logFile -Force | Out-Null

    $cmdLine = "chcp 65001 >nul & `"$ytdlp`" $argString > `"$($script:logFile)`" 2>&1"
    $script:proc    = Start-Process 'cmd.exe' -ArgumentList @('/c', $cmdLine) -WindowStyle Hidden -PassThru
    $script:running = $true

    $displayTitle = if ($next.Title) { $next.Title } else { $next.Url }
    $short = if ($displayTitle.Length -gt 45) { $displayTitle.Substring(0,45) + '…' } else { $displayTitle }
    $TxtStatus.Text       = "↓ $short"
    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::CornflowerBlue
}

$BtnStartAll.Add_Click({
    if ($script:running) { return }
    $pending = @($queueItems | Where-Object { $_.Status -eq 'En attente' })
    if ($pending.Count -eq 0) {
        Show-DarkDialog 'La file est vide. Ajoute des URLs d''abord.' 'File vide' 'ℹ'
        return
    }
    if (-not $ytdlp)  { Show-DarkDialog 'yt-dlp introuvable.' 'Erreur' '✕'; return }
    if (-not $ffmpeg) { Show-DarkDialog 'ffmpeg introuvable.' 'Erreur' '✕'; return }
    $BtnStartAll.IsEnabled = $false
    $BtnCancel.IsEnabled   = $true
    Start-NextDownload
})

$BtnCancel.Add_Click({
    if ($script:proc -and -not $script:proc.HasExited) {
        Start-Process 'taskkill' -ArgumentList @('/F','/T','/PID',$script:proc.Id.ToString()) -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
    }
    if ($script:currentItem) { $script:currentItem.Status = 'Annulé'; $script:currentItem.Progress = 0 }
    $script:running        = $false
    $BtnStartAll.IsEnabled = $true
    $BtnCancel.IsEnabled   = $false
    $TxtStatus.Text        = 'Annulé.'
    $TxtStatus.Foreground  = [System.Windows.Media.Brushes]::Orange
    # Nettoyage fichiers temporaires laissés par yt-dlp
    # On cible uniquement les .part / .ytdl — pas les .webp qui peuvent être légitimes
    try {
        $outDir = $TxtOut.Text
        if (Test-Path $outDir) {
            Get-ChildItem $outDir -File -Recurse | Where-Object {
                $_.Extension -in @('.part', '.ytdl') -or $_.Name -match '\.f\d+\.\w+$'
            } | ForEach-Object {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
    Update-GlobalProgress
})

# ================================================================
#  DispatcherTimer (remplace WinForms Timer)
# ================================================================
$timer          = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)

$timer.Add_Tick({
    try {
        # --- Lecture log download ---
        if ($script:logFile -and (Test-Path $script:logFile)) {
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
                        $ms = [regex]::Matches($chunk, '\[download\]\s+(\d+(?:\.\d+)?)%')
                        if ($ms.Count -gt 0) {
                            $pct = [int][double]$ms[$ms.Count-1].Groups[1].Value
                            $script:currentItem.Progress = [Math]::Max(0,[Math]::Min(100,$pct))
                        }
                        # Parsing vitesse : "at 1.23MiB/s" ou "at 456.78KiB/s"
                        $sv = [regex]::Match($chunk, 'at\s+([\d.]+\s*(?:KiB|MiB|GiB|KB|MB|GB)/s)')
                        if ($sv.Success) { $script:currentItem.Speed = $sv.Groups[1].Value }
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
        if ($script:running -and $script:proc -and $script:proc.HasExited) {
            $exit = $script:proc.ExitCode
            if ($script:currentItem) {
                if ($exit -eq 0) {
                    $script:currentItem.Status   = 'Terminé'
                    $script:currentItem.Progress = 100
                    $script:currentItem.Speed    = ''
                } else {
                    $script:currentItem.Status = "Echec ($exit)"
                    $script:currentItem.Speed  = ''
                }
            }
            $script:running     = $false
            $script:currentItem = $null
            if ($script:logFile) { try { Remove-Item $script:logFile -Force -ErrorAction SilentlyContinue } catch {}; $script:logFile = $null }
            Save-QueueToConfig
            Update-GlobalProgress
            Start-NextDownload
        }

        # --- Meta jobs (fetch titre + thumbnail pour items ajoutés sans preview) ---
        if ($script:pendingMetaJobs.Count -gt 0) {
            $done = @($script:pendingMetaJobs | Where-Object { $_.Job.State -in @('Completed','Failed') })
            foreach ($entry in $done) {
                try {
                    $info = Receive-Job $entry.Job -ErrorAction SilentlyContinue
                    if ($info -and $entry.Item) {
                        if ($info.Title) { $entry.Item.Title = $info.Title }
                        if ($info.Thumb) {
                            try {
                                $wc2   = New-Object System.Net.WebClient
                                $b2    = $wc2.DownloadData($info.Thumb)
                                $ms3   = New-Object System.IO.MemoryStream($b2, 0, $b2.Length)
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
                    # artist > creator > uploader
                    $previewArtist = if ($info.artist)   { $info.artist }
                                     elseif ($info.creator) { $info.creator }
                                     else { $info.uploader }
                    $TxtPreviewChannel.Text = if ($previewArtist) { $previewArtist } else { '' }
                    $dur = if ($info.duration) {
                        $ts = [TimeSpan]::FromSeconds([int]$info.duration)
                        if ($ts.Hours -gt 0) { "{0}:{1:D2}:{2:D2}" -f $ts.Hours,$ts.Minutes,$ts.Seconds }
                        else                 { "{0}:{1:D2}" -f $ts.Minutes,$ts.Seconds }
                    } else { '' }
                    $TxtPreviewDuration.Text = $dur
                    # Thumbnail
                    if ($info.thumbnail) {
                        try {
                            $wc    = New-Object System.Net.WebClient
                            $bytes = $wc.DownloadData($info.thumbnail)
                            $ms2   = New-Object System.IO.MemoryStream($bytes, 0, $bytes.Length)
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
                    $TxtUpdateBadge.Text       = "⬆ v$($res.Tag) dispo"
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
                    $TxtStatus.Text       = "yt-dlp mis a jour : $newVer  ✔"
                    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
                    $TxtYtdlpVer.Text     = "yt-dlp $newVer"
                    $BtnUpdateYtdlp.Visibility = 'Collapsed'
                } else {
                    $TxtStatus.Text       = "Echec mise a jour yt-dlp"
                    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::Tomato
                }
            } catch {}
            Remove-Job $script:updateYtdlpJob -Force -ErrorAction SilentlyContinue
            $script:updateYtdlpJob  = $null
            $BtnUpdateYtdlp.IsEnabled = $true
        }

    } catch { Write-Crash 'DispatcherTimer.Tick' $_ }
})

$timer.Start()

# ================================================================
#  Statut initial (outils)
# ================================================================
if ($ytdlp -and $ffmpeg) {
    $TxtStatus.Text       = 'Prêt'
    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
} else {
    $TxtStatus.Text       = 'yt-dlp ou ffmpeg introuvable'
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
Save-QueueToConfig

# Nettoyage jobs
foreach ($j in @($script:updateJob,$script:ytdlpVerJob,$script:previewJob,$script:updateYtdlpJob)) {
    if ($j) { try { Remove-Job $j -Force -ErrorAction SilentlyContinue } catch {} }
}
if ($script:logFile -and (Test-Path $script:logFile)) {
    try { Remove-Item $script:logFile -Force -ErrorAction SilentlyContinue } catch {}
}
