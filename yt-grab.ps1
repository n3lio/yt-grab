[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ================================================================
#  App metadata
# ================================================================
$AppName    = 'YouTube Grabber by n3lio'
$AppVersion = '2.0.4'
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

if ((-not (Test-Path $ytdlpInApp)) -or (-not (Test-Path $ffmpegInApp))) {
    $splashXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="YouTube Grabber" Height="130" Width="440"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        WindowStyle="None" Background="#12121A" AllowsTransparency="True">
  <Border CornerRadius="12" Background="#12121A" BorderBrush="#3434A0" BorderThickness="1">
    <StackPanel VerticalAlignment="Center" Margin="28,20">
      <TextBlock Text="YouTube Grabber" Foreground="#6366F1" FontFamily="Segoe UI" FontSize="15" FontWeight="Bold"/>
      <TextBlock Text="Premier lancement — telechargement des outils..." Foreground="#9090B0" FontFamily="Segoe UI" FontSize="10" Margin="0,8,0,12"/>
      <ProgressBar IsIndeterminate="True" Height="4" Background="#1E1E2E" Foreground="#6366F1"/>
    </StackPanel>
  </Border>
</Window>
'@
    $splashWin = [Windows.Markup.XamlReader]::Parse($splashXaml)
    $splashWin.Show()
    $splashWin.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

$ytdlp  = Ensure-Tool -Name 'yt-dlp'  -ExeName 'yt-dlp.exe'
$ffmpeg = Ensure-Tool -Name 'ffmpeg'  -ExeName 'ffmpeg.exe'

if ($splashWin) { try { $splashWin.Close() } catch {} }

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
    private string _artist;
    private string _status;
    private int    _progress;
    private string _format;

    public string Url      { get { return _url; }      set { _url = value;      OnChanged("Url"); } }
    public string Title    { get { return _title; }    set { _title = value;    OnChanged("Title");    OnChanged("DisplayTitle"); } }
    public string Artist   { get { return _artist; }   set { _artist = value;   OnChanged("Artist");   OnChanged("DisplayTitle"); } }
    public string Status   { get { return _status; }   set { _status = value;   OnChanged("Status");   OnChanged("RetryVisible"); } }
    public int    Progress { get { return _progress; } set { _progress = value; OnChanged("Progress"); } }
    public string Format   { get { return _format; }   set { _format = value;   OnChanged("Format"); } }

    // Titre affiché : "Artiste - Titre" si artiste connu, sinon juste le titre
    public string DisplayTitle {
        get {
            if (!string.IsNullOrEmpty(_artist) && !string.IsNullOrEmpty(_title))
                return _artist + " — " + _title;
            if (!string.IsNullOrEmpty(_title)) return _title;
            return _url;
        }
    }

    // Bouton relancer visible si Annulé ou Echec
    public string RetryVisible {
        get { return (_status == "Annulé" || (_status != null && _status.StartsWith("Echec"))) ? "Visible" : "Collapsed"; }
    }

    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnChanged(string n) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(n)); }
}
'@

$queueItems = New-Object System.Collections.ObjectModel.ObservableCollection[QueueItem]

# ================================================================
#  XAML principal
# ================================================================
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="YouTube Grabber by n3lio"
    Width="780" Height="560" MinWidth="700" MinHeight="480"
    WindowStartupLocation="CenterScreen"
    Background="#0E0E16"
    FontFamily="Segoe UI"
    WindowStyle="None"
    AllowsTransparency="True"
    ResizeMode="CanResizeWithGrip">

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

    <!-- ComboBox dark -->
    <Style x:Key="CmbDark" TargetType="ComboBox">
      <Setter Property="Background"      Value="#1E1E30"/>
      <Setter Property="Foreground"      Value="#E8E8F0"/>
      <Setter Property="BorderBrush"     Value="#2E2E4A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding"         Value="10,6"/>
      <Setter Property="FontSize"        Value="12"/>
    </Style>

    <!-- ProgressBar dark -->
    <Style x:Key="PrgDark" TargetType="ProgressBar">
      <Setter Property="Background" Value="#1E1E30"/>
      <Setter Property="Foreground" Value="#6366F1"/>
      <Setter Property="Height"     Value="6"/>
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
        <Grid Margin="16,0">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="10" Height="10" Fill="#6366F1" Margin="0,0,8,0"/>
            <TextBlock Text="YouTube Grabber" Foreground="#E8E8F0" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtVersion" Text="" Foreground="#8888AA" FontSize="11" VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtYtdlpVer" Text="" Foreground="#555570" FontSize="10" VerticalAlignment="Center" Margin="10,0,0,0"/>
            <TextBlock x:Name="TxtUpdateBadge" Text="" Foreground="#E59700" FontSize="11"
                       VerticalAlignment="Center" Margin="10,0,0,0" Cursor="Hand"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" >
            <!-- Boutons avec foreground explicite pour être visibles sur fond sombre -->
            <Button x:Name="BtnAbout"    Width="28" Height="28" Style="{StaticResource BtnSecondary}" FontWeight="Bold" Margin="0,0,6,0">
              <TextBlock Text="?" Foreground="#C0C0D8" FontSize="13" FontWeight="Bold"/>
            </Button>
            <Button x:Name="BtnMinimize" Width="28" Height="28" Style="{StaticResource BtnSecondary}" Margin="0,0,6,0">
              <TextBlock Text="─" Foreground="#C0C0D8" FontSize="13"/>
            </Button>
            <Button x:Name="BtnClose"    Width="28" Height="28" Style="{StaticResource BtnDanger}">
              <TextBlock Text="✕" Foreground="#F85149" FontSize="13"/>
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
          <ComboBox x:Name="CmbUrl" Grid.Column="0" Height="38" Style="{StaticResource CmbDark}"
                    IsEditable="True" Margin="0,0,8,0"
                    Text="" FontSize="12"/>
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
          <TextBox x:Name="TxtOut" Grid.Column="0" Height="36" Style="{StaticResource TxtDark}"
                   IsReadOnly="True" Margin="0,0,8,0" VerticalContentAlignment="Center"/>
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
                <TextBlock Text="File d'attente" Foreground="#9090B0" FontSize="12"
                           FontWeight="SemiBold" VerticalAlignment="Center"/>
                <Button x:Name="BtnClearDone" Content="Effacer terminés" HorizontalAlignment="Right"
                        Style="{StaticResource BtnSecondary}" Height="26" Padding="12,0" FontSize="12"
                        VerticalAlignment="Center"/>
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
                  <Grid Margin="14,8">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="110"/>
                      <ColumnDefinition Width="60"/>
                      <ColumnDefinition Width="28"/>
                      <ColumnDefinition Width="28"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" VerticalAlignment="Center">
                      <TextBlock Text="{Binding DisplayTitle}" Foreground="#E8E8F0" FontSize="12"
                                 TextTrimming="CharacterEllipsis"/>
                      <TextBlock Text="{Binding Url}" Foreground="#4A4A6A" FontSize="9"
                                 TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                    <ProgressBar Grid.Column="1" Value="{Binding Progress}" Maximum="100" Minimum="0"
                                 Style="{StaticResource PrgDark}" VerticalAlignment="Center" Margin="10,0"/>
                    <TextBlock Grid.Column="2" Text="{Binding Status}" Foreground="#6B6B8A"
                               FontSize="10" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                    <!-- Bouton relancer (visible seulement si Annulé ou Echec) -->
                    <Button Grid.Column="3" Content="↺" Tag="{Binding}" Width="24" Height="24"
                            x:Name="BtnRetryItem"
                            Style="{StaticResource BtnOk}" Padding="0" FontSize="13"
                            VerticalAlignment="Center" HorizontalAlignment="Center"
                            Visibility="{Binding RetryVisible}"/>
                    <Button Grid.Column="4" Content="✕" Tag="{Binding}" Width="24" Height="24"
                            x:Name="BtnRemoveItem"
                            Style="{StaticResource BtnDanger}" Padding="0" FontSize="10"
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
$RdoMp4          = Find-Ctrl 'RdoMp4'
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
            [System.Windows.MessageBox]::Show('URL YouTube invalide.', $AppName, 'OK', 'Warning') | Out-Null
            return
        }
        # Évite les doublons en attente
        $already = $queueItems | Where-Object { $_.Url -eq $cleaned -and $_.Status -in @('En attente','En cours') }
        if ($already) { return }

        $fmt = if ($RdoMp3.IsChecked) { 'MP3' } else { 'MP4' }
        $item = [QueueItem]::new()
        $item.Url      = $cleaned
        $item.Title    = ''   # sera rempli par preview ou fetch background
        $item.Artist   = ''
        $item.Status   = 'En attente'
        $item.Progress = 0
        $item.Format   = $fmt

        # Si la preview est déjà chargée, on l'utilise directement
        if ($TxtPreviewTitle.Text -and $TxtPreviewTitle.Text -ne '') {
            $item.Title  = $TxtPreviewTitle.Text
            $item.Artist = $TxtPreviewChannel.Text
        }

        $queueItems.Add($item)

        # Si pas de titre → fetch en background
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
                        # artist > creator > uploader (du plus précis au moins précis)
                        $art = if ($info.artist)  { $info.artist }
                               elseif ($info.creator) { $info.creator }
                               else { $info.uploader }
                        return [PSCustomObject]@{ Title = $info.title; Artist = $art }
                    }
                } catch {}
                return $null
            } -ArgumentList $ytdlpPath, $urlRef | ForEach-Object {
                # On stocke le job et la ref item ensemble pour le polling dans le Timer
                $script:pendingMetaJobs += [PSCustomObject]@{ Job = $_; Item = $itemRef }
            }
        }
        $TxtQueueEmpty.Visibility = 'Collapsed'
        Save-HistoryUrl $cleaned
        $CmbUrl.Items.Clear()
        foreach ($h in $historyList) { $CmbUrl.Items.Add($h) | Out-Null }
        $CmbUrl.Text = ''
        $PreviewCard.Visibility = 'Collapsed'
    } catch { Write-Crash 'BtnAddQueue' $_ }
})

# Boutons dans la queue (supprimer + relancer)
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
            }
        } elseif ($btn.Name -eq 'BtnRetryItem') {
            $item.Status   = 'En attente'
            $item.Progress = 0
        }
    }
)

$BtnClearDone.Add_Click({
    $done = @($queueItems | Where-Object { $_.Status -in @('Terminé','Echec','Annulé') })
    foreach ($d in $done) { $queueItems.Remove($d) | Out-Null }
    if ($queueItems.Count -eq 0) { $TxtQueueEmpty.Visibility = 'Visible' }
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

function Start-NextDownload {
    $next = $queueItems | Where-Object { $_.Status -eq 'En attente' } | Select-Object -First 1
    if (-not $next) {
        $script:running = $false
        $BtnStartAll.IsEnabled = $true
        $BtnCancel.IsEnabled   = $false
        $TxtStatus.Text      = 'Tout terminé ✔'
        $TxtStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
        # Toast Windows
        try {
            [System.Windows.Forms.Application]::EnableVisualStyles()
            $notify = New-Object System.Windows.Forms.NotifyIcon
            $notify.Icon = [System.Drawing.SystemIcons]::Information
            $notify.Visible = $true
            $notify.BalloonTipTitle = 'YouTube Grabber'
            $notify.BalloonTipText  = 'Tous les telechargements sont termines !'
            $notify.ShowBalloonTip(4000)
            Start-Sleep -Milliseconds 4500
            $notify.Dispose()
        } catch {}
        return
    }

    $script:currentItem = $next
    $next.Status   = 'En cours'
    $next.Progress = 0
    $out = $TxtOut.Text
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

    $ytArgs = New-Object System.Collections.Generic.List[string]

    if ($next.Format -eq 'MP3') {
        $ytArgs.Add('-x'); $ytArgs.Add('--audio-format'); $ytArgs.Add('mp3')
        $ytArgs.Add('--audio-quality'); $ytArgs.Add('0')
    } else {
        $ytArgs.Add('-f'); $ytArgs.Add('bv*+ba/b')
        $ytArgs.Add('--merge-output-format'); $ytArgs.Add('mp4')
    }

    # Métadonnées filtrées (titre, artiste, album, genre, année, track, disc — pas de commentaires)
    if ($ChkMeta.IsChecked) {
        $ytArgs.Add('--embed-thumbnail')
        $ytArgs.Add('--add-metadata')
        # On post-process avec mutagen via yt-dlp pour retirer les champs indésirables
        # yt-dlp supporte --parse-metadata pour écraser les champs
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add('%(title)s:%(meta_title)s')
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add('%(uploader)s:%(meta_artist)s')
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add('%(upload_date>%Y)s:%(meta_date)s')
        # Nettoie commentaire et description (souvent du spam)
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add(':%(meta_comment)s')
        $ytArgs.Add('--parse-metadata'); $ytArgs.Add(':%(meta_description)s')
    }

    if ($ChkPlaylist.IsChecked) { $ytArgs.Add('--yes-playlist') } else { $ytArgs.Add('--no-playlist') }

    if ($ChkSubs.IsChecked) {
        $ytArgs.Add('--write-subs'); $ytArgs.Add('--write-auto-subs')
        $ytArgs.Add('--sub-langs'); $ytArgs.Add('fr,en')
        $ytArgs.Add('--convert-subs'); $ytArgs.Add('srt')
    }

    # Template nom de fichier :
    # MP3 vidéo unique : "Artiste - Titre" (artist > creator > uploader, puis titre seul si rien)
    # MP4 / playlist : comportement classique
    $template = if ($ChkPlaylist.IsChecked) {
        Join-Path $out '%(playlist_title)s\%(playlist_index)s - %(title)s.%(ext)s'
    } elseif ($next.Format -eq 'MP3') {
        # %(artist,creator,uploader)s = prend le premier champ non vide dans l'ordre
        Join-Path $out '%(artist,creator,uploader)s - %(title)s.%(ext)s'
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

    $TxtStatus.Text       = "Telechargement : $($next.Title.Substring(0, [Math]::Min(40, $next.Title.Length)))..."
    $TxtStatus.Foreground = [System.Windows.Media.Brushes]::CornflowerBlue
}

$BtnStartAll.Add_Click({
    if ($script:running) { return }
    $pending = @($queueItems | Where-Object { $_.Status -eq 'En attente' })
    if ($pending.Count -eq 0) {
        [System.Windows.MessageBox]::Show('La file est vide. Ajoute des URLs d''abord.', $AppName, 'OK', 'Information') | Out-Null
        return
    }
    if (-not $ytdlp) { [System.Windows.MessageBox]::Show('yt-dlp introuvable.', $AppName, 'OK', 'Error') | Out-Null; return }
    if (-not $ffmpeg) { [System.Windows.MessageBox]::Show('ffmpeg introuvable.', $AppName, 'OK', 'Error') | Out-Null; return }
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
                        $ms = [regex]::Matches($chunk, '\[download\]\s+(\d+(?:\.\d+)?)%')
                        if ($ms.Count -gt 0) {
                            $pct = [int][double]$ms[$ms.Count-1].Groups[1].Value
                            $script:currentItem.Progress = [Math]::Max(0,[Math]::Min(100,$pct))
                        }
                    }
                }
            } finally { if ($fs) { $fs.Dispose() } }
        }

        # --- Process terminé ---
        if ($script:running -and $script:proc -and $script:proc.HasExited) {
            $exit = $script:proc.ExitCode
            if ($script:currentItem) {
                if ($exit -eq 0) { $script:currentItem.Status = 'Terminé'; $script:currentItem.Progress = 100 }
                else             { $script:currentItem.Status = "Echec ($exit)" }
            }
            $script:running     = $false
            $script:currentItem = $null
            if ($script:logFile) { try { Remove-Item $script:logFile -Force -ErrorAction SilentlyContinue } catch {}; $script:logFile = $null }
            # Passe au suivant
            Start-NextDownload
        }

        # --- Meta jobs (fetch titre/artiste pour items ajoutés sans preview) ---
        if ($script:pendingMetaJobs.Count -gt 0) {
            $done = @($script:pendingMetaJobs | Where-Object { $_.Job.State -in @('Completed','Failed') })
            foreach ($entry in $done) {
                try {
                    $info = Receive-Job $entry.Job -ErrorAction SilentlyContinue
                    if ($info -and $entry.Item) {
                        if ($info.Title)  { $entry.Item.Title  = $info.Title }
                        if ($info.Artist) { $entry.Item.Artist = $info.Artist }
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

# Nettoyage jobs
foreach ($j in @($script:updateJob,$script:ytdlpVerJob,$script:previewJob,$script:updateYtdlpJob)) {
    if ($j) { try { Remove-Job $j -Force -ErrorAction SilentlyContinue } catch {} }
}
if ($script:logFile -and (Test-Path $script:logFile)) {
    try { Remove-Item $script:logFile -Force -ErrorAction SilentlyContinue } catch {}
}
