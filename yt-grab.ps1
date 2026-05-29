[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Le exe compile (-NoConsole) n'a pas de console ; on tente l'UTF-8 mais on
# ignore si ca echoue.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ----------------- App metadata (mettre à jour à chaque release) -----------------

$AppName    = 'My YouTube Downloader'
$AppVersion = '1.4.0'
$AppAuthor  = 'n3lio'
$AppRepo    = 'https://github.com/n3lio/yt-grab'

# Quand on tourne en exe (PS2EXE), $MyInvocation.MyCommand.Path peut etre vide.
# Fallback : repertoire de l'exe lui-meme.
$scriptDir = $null
try {
    if ($MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
} catch {}
if (-not $scriptDir) {
    try { $scriptDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {}
}
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$crashLog = Join-Path $scriptDir 'yt-grab-crash.log'

function Write-Crash {
    param([string]$Where, $ErrObj)
    try {
        $msg = "[$(Get-Date -Format o)] $Where`n"
        if ($ErrObj) {
            $msg += ($ErrObj | Out-String)
            if ($ErrObj.ScriptStackTrace) { $msg += "`n$($ErrObj.ScriptStackTrace)`n" }
            if ($ErrObj.Exception) { $msg += "`n$($ErrObj.Exception.ToString())`n" }
        }
        $msg += "`n----`n"
        Add-Content -Path $crashLog -Value $msg -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    [System.Windows.Forms.MessageBox]::Show("Echec du chargement WinForms : $($_.Exception.Message)", 'yt-grab', 'OK', 'Error') | Out-Null
    Write-Crash -Where 'Add-Type' -ErrObj $_
    return
}

$configFile = Join-Path $scriptDir 'yt-grab.config.json'

function Read-Config {
    if (Test-Path $configFile) {
        try { return Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Save-Config {
    param($Config)
    $Config | ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8
}

# Cherche un outil, et si introuvable le télécharge automatiquement dans $scriptDir.
# Retourne le chemin complet ou $null si échec.
function Ensure-Tool {
    param([string]$Name, [string]$ExeName)

    # 1. Config mémorisée
    $config = Read-Config
    if ($config -and $config.$Name -and (Test-Path $config.$Name)) { return $config.$Name }

    # 2. Dans le dossier de l'app en premier (Program Files\yt-grab\)
    $inApp = Join-Path $scriptDir $ExeName
    if (Test-Path $inApp) { return $inApp }

    # 3. Dans le PATH système
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 4. Scan rapide des emplacements courants (cas où l'utilisateur l'avait déjà)
    $roots = @(
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Downloads\yt-dlp'),
        (Join-Path $env:USERPROFILE 'Downloads\ffmpeg\bin'),
        'C:\ffmpeg\bin',
        'C:\Program Files\ffmpeg\bin'
    )
    foreach ($root in $roots) {
        $candidate = Join-Path $root $ExeName
        if (Test-Path $candidate) {
            # Trouvé ailleurs — on le mémorise dans la config
            $cfg = Read-Config
            if (-not $cfg) { $cfg = [PSCustomObject]@{} }
            if ($cfg.PSObject.Properties.Name -contains $Name) { $cfg.$Name = $candidate }
            else { $cfg | Add-Member -NotePropertyName $Name -NotePropertyValue $candidate }
            Save-Config $cfg
            return $candidate
        }
    }

    # 5. Pas trouvé → téléchargement automatique dans $scriptDir
    $dest = Join-Path $scriptDir $ExeName
    $ok   = $false

    try {
        if ($Name -eq 'yt-dlp') {
            # GitHub Releases : yt-dlp/yt-dlp — asset yt-dlp.exe
            $apiUrl  = 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'
            $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $asset   = $release.assets | Where-Object { $_.name -eq 'yt-dlp.exe' } | Select-Object -First 1
            if (-not $asset) { throw 'Asset yt-dlp.exe introuvable dans la release.' }
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing -ErrorAction Stop
            $ok = $true
        }
        elseif ($Name -eq 'ffmpeg') {
            # On télécharge ffmpeg-master-latest-win64-gpl.zip depuis gyan.dev (build statique officielle)
            $zipUrl  = 'https://github.com/GyanD/codexffmpeg/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
            $zipDest = Join-Path $env:TEMP 'ffmpeg-latest.zip'
            $extract = Join-Path $env:TEMP 'ffmpeg-extract'
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipDest -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zipDest -DestinationPath $extract -Force
            # Le zip contient un sous-dossier ffmpeg-xxx/bin/ffmpeg.exe
            $found = Get-ChildItem -Path $extract -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $found) { throw 'ffmpeg.exe introuvable dans le zip.' }
            Copy-Item $found.FullName $dest -Force
            Remove-Item $zipDest -Force -ErrorAction SilentlyContinue
            Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
            $ok = $true
        }
    } catch {
        Write-Crash -Where "Ensure-Tool:download:$Name" -ErrObj $_
    }

    if ($ok -and (Test-Path $dest)) {
        # Mémorise le chemin
        $cfg = Read-Config
        if (-not $cfg) { $cfg = [PSCustomObject]@{} }
        if ($cfg.PSObject.Properties.Name -contains $Name) { $cfg.$Name = $dest }
        else { $cfg | Add-Member -NotePropertyName $Name -NotePropertyValue $dest }
        Save-Config $cfg
        return $dest
    }

    return $null
}

function Quote-Arg {
    param([string]$Arg)
    if ($Arg -match '[\s"&|<>^()%]') {
        $escaped = $Arg -replace '"', '\"'
        return '"' + $escaped + '"'
    }
    return $Arg
}

function Clean-YouTubeUrl {
    # NB: ne pas nommer le parametre $Input — c'est une variable automatique
    # reservee par PowerShell, le binding casse en exe compile.
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

    try {
        $uri = [System.Uri]$matched
    } catch {
        return $matched
    }

    # NB: ne pas nommer cette variable $host — reservee par PowerShell aussi.
    $uriHost = $uri.Host.ToLower()
    $path = $uri.AbsolutePath
    $query = @{}
    if ($uri.Query) {
        foreach ($kv in $uri.Query.TrimStart('?').Split('&')) {
            if (-not $kv) { continue }
            $parts = $kv.Split('=', 2)
            $k = $parts[0]
            $v = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $query[$k] = $v
        }
    }

    if ($uriHost -like '*youtu.be*') {
        $videoId = $path.TrimStart('/').Split('/')[0]
        if (-not $videoId) { return $matched }
        if ($query.ContainsKey('list')) {
            return "https://www.youtube.com/watch?v=$videoId&list=$($query['list'])"
        }
        return "https://www.youtube.com/watch?v=$videoId"
    }

    if ($path -eq '/watch') {
        if (-not $query.ContainsKey('v')) { return $matched }
        $clean = "https://www.youtube.com/watch?v=$($query['v'])"
        if ($query.ContainsKey('list')) { $clean += "&list=$($query['list'])" }
        return $clean
    }

    if ($path -eq '/playlist') {
        if ($query.ContainsKey('list')) { return "https://www.youtube.com/playlist?list=$($query['list'])" }
        return $matched
    }

    if ($path -like '/shorts/*') {
        $videoId = $path.Substring('/shorts/'.Length).Split('/')[0]
        return "https://www.youtube.com/shorts/$videoId"
    }

    return $matched
}

# Compare deux versions semver. Retourne -1, 0 ou 1.
function Compare-Version {
    param([string]$Va, [string]$Vb)
    $a = $Va.TrimStart('v').Split('.') | ForEach-Object { try { [int]$_ } catch { 0 } }
    $b = $Vb.TrimStart('v').Split('.') | ForEach-Object { try { [int]$_ } catch { 0 } }
    $len = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $na = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $nb = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($na -lt $nb) { return -1 }
        if ($na -gt $nb) { return 1 }
    }
    return 0
}

# Retourne 'playlist', 'video' ou 'unknown' a partir d'une URL brute
function Detect-UrlType {
    param([string]$Url)
    if (-not $Url) { return 'unknown' }
    $u = $Url.Trim()
    if ($u -match 'youtube\.com/playlist\?') { return 'playlist' }
    if ($u -match 'youtu\.be/|youtube\.com/shorts/') { return 'video' }
    if ($u -match 'youtube\.com/watch\?') {
        # watch?v=xxx&list=yyy → vidéo (appartient à une playlist mais on dl la vidéo)
        return 'video'
    }
    return 'unknown'
}

# Télécharge automatiquement yt-dlp et ffmpeg si absents (dans Program Files\yt-grab\)
# Un splash minimaliste pour ne pas laisser l'utilisateur devant une fenêtre vide
$splashNeeded = $false
$cfgCheck = Read-Config
$ytdlpInApp  = Join-Path $scriptDir 'yt-dlp.exe'
$ffmpegInApp = Join-Path $scriptDir 'ffmpeg.exe'
if ((-not (Test-Path $ytdlpInApp)) -or (-not (Test-Path $ffmpegInApp))) {
    $splashNeeded = $true
}

if ($splashNeeded) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $splash = New-Object System.Windows.Forms.Form
    $splash.Text = $AppName
    $splash.Size = New-Object System.Drawing.Size(420, 110)
    $splash.StartPosition = 'CenterScreen'
    $splash.FormBorderStyle = 'FixedSingle'
    $splash.MaximizeBox = $false
    $splash.MinimizeBox = $false
    $splash.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 22)
    $splashLbl = New-Object System.Windows.Forms.Label
    $splashLbl.Text = "Premier lancement — telechargement des outils en cours..."
    $splashLbl.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 200)
    $splashLbl.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $splashLbl.Location = New-Object System.Drawing.Point(20, 20)
    $splashLbl.AutoSize = $true
    $splash.Controls.Add($splashLbl)
    $splashBar = New-Object System.Windows.Forms.ProgressBar
    $splashBar.Location = New-Object System.Drawing.Point(20, 50)
    $splashBar.Size = New-Object System.Drawing.Size(370, 10)
    $splashBar.Style = 'Marquee'
    $splashBar.MarqueeAnimationSpeed = 30
    $splash.Controls.Add($splashBar)
    $splash.Show()
    $splash.Refresh()
}

$ytdlp  = Ensure-Tool -Name 'yt-dlp'  -ExeName 'yt-dlp.exe'
$ffmpeg = Ensure-Tool -Name 'ffmpeg'  -ExeName 'ffmpeg.exe'

if ($splashNeeded) {
    try { $splash.Close(); $splash.Dispose() } catch {}
}

if (-not $ytdlp) {
    [System.Windows.Forms.MessageBox]::Show(
        "Impossible de telecharger yt-dlp.exe automatiquement.`nVerifie ta connexion internet ou telecharge-le manuellement depuis https://github.com/yt-dlp/yt-dlp/releases et place-le dans :`n$scriptDir",
        $AppName, 'OK', 'Error') | Out-Null
}
if (-not $ffmpeg) {
    [System.Windows.Forms.MessageBox]::Show(
        "Impossible de telecharger ffmpeg.exe automatiquement.`nVerifie ta connexion internet ou telecharge-le manuellement depuis https://ffmpeg.org/download.html et place-le dans :`n$scriptDir",
        $AppName, 'OK', 'Error') | Out-Null
}

# Dossier de destination : dernier dossier mémorisé, sinon Téléchargements Windows
$windowsDownloads = Join-Path $env:USERPROFILE 'Downloads'
$cfg0 = Read-Config
$defaultOut = $windowsDownloads
if ($cfg0 -and ($cfg0.PSObject.Properties.Name -contains 'lastFolder') -and $cfg0.lastFolder -and (Test-Path $cfg0.lastFolder)) {
    $defaultOut = $cfg0.lastFolder
}

# Historique (10 dernières URLs)
$historyList = New-Object System.Collections.Generic.List[string]
if ($cfg0 -and ($cfg0.PSObject.Properties.Name -contains 'history') -and $cfg0.history) {
    foreach ($h in $cfg0.history) { if ($h) { $historyList.Add($h) } }
}

function Save-HistoryUrl {
    param([string]$Url)
    $historyList.Remove($Url) | Out-Null
    $historyList.Insert(0, $Url)
    while ($historyList.Count -gt 10) { $historyList.RemoveAt($historyList.Count - 1) }
    $cfgHist = Read-Config
    if (-not $cfgHist) { $cfgHist = [PSCustomObject]@{} }
    $arr = $historyList.ToArray()
    if ($cfgHist.PSObject.Properties.Name -contains 'history') { $cfgHist.history = $arr }
    else { $cfgHist | Add-Member -NotePropertyName 'history' -NotePropertyValue $arr }
    Save-Config $cfgHist
}

# ----------------- Auto-update check (GitHub Releases, non bloquant) -----------------
# On lance un Job PowerShell en parallele ; le Timer principal le pollera.
$script:updateJob = $null
$script:updateAvailable = $null   # sera rempli par le timer si update trouve
try {
    $script:updateJob = Start-Job -ScriptBlock {
        param($repo, $current)
        try {
            $url = "https://api.github.com/repos/$repo/releases/latest"
            $resp = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop
            $latest = $resp.tag_name
            $dl     = ($resp.assets | Where-Object { $_.name -like '*-setup.exe' } | Select-Object -First 1).browser_download_url
            if (-not $dl) { $dl = $resp.html_url }
            return [PSCustomObject]@{ Latest = $latest; DownloadUrl = $dl }
        } catch {
            return $null
        }
    } -ArgumentList 'n3lio/yt-grab', $AppVersion
} catch {}

# ----------------- Palette dark -----------------
# Couleurs définies une seule fois, référencées partout
$cBg       = [System.Drawing.Color]::FromArgb(18,  18,  22)   # fond fenêtre
$cSurface  = [System.Drawing.Color]::FromArgb(28,  28,  34)   # groupbox / textbox
$cBorder   = [System.Drawing.Color]::FromArgb(52,  52,  64)   # bords discrets
$cText     = [System.Drawing.Color]::FromArgb(220, 220, 228)   # texte principal
$cMuted    = [System.Drawing.Color]::FromArgb(110, 110, 130)   # labels secondaires
$cAccent   = [System.Drawing.Color]::FromArgb(99,  102, 241)   # indigo vif (bouton go)
$cAccentHo = [System.Drawing.Color]::FromArgb(129, 132, 255)   # hover accent
$cDanger   = [System.Drawing.Color]::FromArgb(248, 81,  73)    # rouge annuler
$cOk       = [System.Drawing.Color]::FromArgb(63,  185, 80)    # vert succès
$cWarn     = [System.Drawing.Color]::FromArgb(229, 151, 0)     # orange update

# Helper : applique le style dark à un GroupBox et ses enfants
function Style-GroupBox {
    param($Grp)
    $Grp.ForeColor = $cMuted
    $Grp.BackColor = $cSurface
    foreach ($ctrl in $Grp.Controls) {
        $ctrl.BackColor = $cSurface
        $ctrl.ForeColor = $cText
    }
}

# Helper : style bouton secondaire (plat, bord subtil)
function Style-BtnSecondary {
    param($Btn, [string]$Fg = '')
    $Btn.FlatStyle = 'Flat'
    $Btn.BackColor = $cSurface
    $Btn.ForeColor = if ($Fg) { [System.Drawing.Color]::FromArgb([int]"0x$($Fg.TrimStart('#').Substring(0,2))", [int]"0x$($Fg.TrimStart('#').Substring(2,2))", [int]"0x$($Fg.TrimStart('#').Substring(4,2))") } else { $cText }
    $Btn.FlatAppearance.BorderColor = $cBorder
    $Btn.FlatAppearance.BorderSize  = 1
    $Btn.FlatAppearance.MouseOverBackColor = $cBorder
}

# (on n'appelle pas Style-BtnSecondary avec un hex — on le fera inline pour éviter la complexité de parsing)

# ----------------- UI dimensions -----------------

$collapsedHeight = 400
$expandedHeight  = 650

# ----------------- UI build -----------------

$form = New-Object System.Windows.Forms.Form
$form.Text            = $AppName
$form.Size            = New-Object System.Drawing.Size(740, $collapsedHeight)
$form.MinimumSize     = New-Object System.Drawing.Size(680, $collapsedHeight)
$form.StartPosition   = 'CenterScreen'
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor       = $cBg
$form.ForeColor       = $cText

# ---- Bouton "?" — coin supérieur droit ----
$btnAbout             = New-Object System.Windows.Forms.Button
$btnAbout.Text        = '?'
$btnAbout.Size        = New-Object System.Drawing.Size(30, 24)
$btnAbout.Location    = New-Object System.Drawing.Point(698, 5)
$btnAbout.Anchor      = 'Top, Right'
$btnAbout.Font        = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnAbout.FlatStyle   = 'Flat'
$btnAbout.BackColor   = $cSurface
$btnAbout.ForeColor   = $cMuted
$btnAbout.FlatAppearance.BorderColor = $cBorder
$btnAbout.FlatAppearance.BorderSize  = 1
$btnAbout.FlatAppearance.MouseOverBackColor = $cBorder
$form.Controls.Add($btnAbout)

# ---- Label URL ----
$lblUrl               = New-Object System.Windows.Forms.Label
$lblUrl.Text          = 'URL YouTube'
$lblUrl.Location      = New-Object System.Drawing.Point(16, 14)
$lblUrl.AutoSize      = $true
$lblUrl.ForeColor     = $cMuted
$lblUrl.Font          = New-Object System.Drawing.Font('Segoe UI', 8)
$form.Controls.Add($lblUrl)

# ---- ComboBox URL avec historique ----
$cmbUrl               = New-Object System.Windows.Forms.ComboBox
$cmbUrl.Location      = New-Object System.Drawing.Point(16, 31)
$cmbUrl.Size          = New-Object System.Drawing.Size(690, 26)
$cmbUrl.Anchor        = 'Top, Left, Right'
$cmbUrl.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$cmbUrl.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::None
$cmbUrl.BackColor     = $cSurface
$cmbUrl.ForeColor     = $cText
$cmbUrl.FlatStyle     = 'Flat'
foreach ($h in $historyList) { $cmbUrl.Items.Add($h) | Out-Null }
$form.Controls.Add($cmbUrl)

# ---- Label détection ----
$lblDetect            = New-Object System.Windows.Forms.Label
$lblDetect.Text       = ''
$lblDetect.Location   = New-Object System.Drawing.Point(16, 60)
$lblDetect.Size       = New-Object System.Drawing.Size(690, 16)
$lblDetect.Font       = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)
$lblDetect.ForeColor  = $cMuted
$lblDetect.Anchor     = 'Top, Left, Right'
$form.Controls.Add($lblDetect)

$cmbUrl.Add_TextChanged({
    try {
        $detected = Detect-UrlType -Url $cmbUrl.Text
        switch ($detected) {
            'playlist' {
                $lblDetect.Text      = '▶  Playlist detectee — "Toute la playlist" coché automatiquement'
                $lblDetect.ForeColor = $cAccent
                $chkPlaylist.Checked = $true
            }
            'video' {
                $lblDetect.Text      = '▶  Video unique'
                $lblDetect.ForeColor = $cOk
                $chkPlaylist.Checked = $false
            }
            default {
                $lblDetect.Text = ''
            }
        }
    } catch {}
})

# ---- Séparateur visuel (panel fin) ----
$sep1             = New-Object System.Windows.Forms.Panel
$sep1.Location    = New-Object System.Drawing.Point(16, 82)
$sep1.Size        = New-Object System.Drawing.Size(690, 1)
$sep1.BackColor   = $cBorder
$sep1.Anchor      = 'Top, Left, Right'
$form.Controls.Add($sep1)

# ---- GroupBox Format ----
$grpFormat             = New-Object System.Windows.Forms.GroupBox
$grpFormat.Text        = 'Format'
$grpFormat.Location    = New-Object System.Drawing.Point(16, 92)
$grpFormat.Size        = New-Object System.Drawing.Size(336, 72)
$grpFormat.ForeColor   = $cMuted
$grpFormat.BackColor   = $cSurface

$rdoMp4               = New-Object System.Windows.Forms.RadioButton
$rdoMp4.Text          = 'MP4 — qualite max (video + audio)'
$rdoMp4.Location      = New-Object System.Drawing.Point(12, 20)
$rdoMp4.AutoSize      = $true
$rdoMp4.BackColor     = $cSurface
$rdoMp4.ForeColor     = $cText
$grpFormat.Controls.Add($rdoMp4)

$rdoMp3               = New-Object System.Windows.Forms.RadioButton
$rdoMp3.Text          = 'MP3 — audio seul (320 kbps)'
$rdoMp3.Location      = New-Object System.Drawing.Point(12, 44)
$rdoMp3.AutoSize      = $true
$rdoMp3.BackColor     = $cSurface
$rdoMp3.ForeColor     = $cText
$rdoMp3.Checked       = $true
$grpFormat.Controls.Add($rdoMp3)
$form.Controls.Add($grpFormat)

# ---- GroupBox Options ----
$grpOpts              = New-Object System.Windows.Forms.GroupBox
$grpOpts.Text         = 'Options'
$grpOpts.Location     = New-Object System.Drawing.Point(362, 92)
$grpOpts.Size         = New-Object System.Drawing.Size(344, 72)
$grpOpts.ForeColor    = $cMuted
$grpOpts.BackColor    = $cSurface

$chkPlaylist          = New-Object System.Windows.Forms.CheckBox
$chkPlaylist.Text     = 'Toute la playlist (si URL playlist)'
$chkPlaylist.Location = New-Object System.Drawing.Point(12, 20)
$chkPlaylist.AutoSize = $true
$chkPlaylist.BackColor = $cSurface
$chkPlaylist.ForeColor = $cText
$grpOpts.Controls.Add($chkPlaylist)

$chkSubs              = New-Object System.Windows.Forms.CheckBox
$chkSubs.Text         = 'Inclure sous-titres si dispo (.srt)'
$chkSubs.Location     = New-Object System.Drawing.Point(12, 44)
$chkSubs.AutoSize     = $true
$chkSubs.BackColor    = $cSurface
$chkSubs.ForeColor    = $cText
$grpOpts.Controls.Add($chkSubs)
$form.Controls.Add($grpOpts)

# ---- Séparateur ----
$sep2             = New-Object System.Windows.Forms.Panel
$sep2.Location    = New-Object System.Drawing.Point(16, 174)
$sep2.Size        = New-Object System.Drawing.Size(690, 1)
$sep2.BackColor   = $cBorder
$sep2.Anchor      = 'Top, Left, Right'
$form.Controls.Add($sep2)

# ---- Label dossier ----
$lblOut           = New-Object System.Windows.Forms.Label
$lblOut.Text      = 'Dossier de destination'
$lblOut.Location  = New-Object System.Drawing.Point(16, 182)
$lblOut.AutoSize  = $true
$lblOut.ForeColor = $cMuted
$lblOut.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
$form.Controls.Add($lblOut)

# ---- Champ dossier (read-only) ----
$txtOut           = New-Object System.Windows.Forms.TextBox
$txtOut.Location  = New-Object System.Drawing.Point(16, 198)
$txtOut.Size      = New-Object System.Drawing.Size(588, 25)
$txtOut.Text      = $defaultOut
$txtOut.Anchor    = 'Top, Left, Right'
$txtOut.ReadOnly  = $true
$txtOut.BackColor = $cSurface
$txtOut.ForeColor = $cText
$txtOut.BorderStyle = 'FixedSingle'
$form.Controls.Add($txtOut)

# ---- Bouton Changer ----
$btnBrowse             = New-Object System.Windows.Forms.Button
$btnBrowse.Text        = 'Changer...'
$btnBrowse.Location    = New-Object System.Drawing.Point(614, 196)
$btnBrowse.Size        = New-Object System.Drawing.Size(92, 26)
$btnBrowse.Anchor      = 'Top, Right'
$btnBrowse.FlatStyle   = 'Flat'
$btnBrowse.BackColor   = $cSurface
$btnBrowse.ForeColor   = $cText
$btnBrowse.FlatAppearance.BorderColor = $cBorder
$btnBrowse.FlatAppearance.BorderSize  = 1
$btnBrowse.FlatAppearance.MouseOverBackColor = $cBorder
$btnBrowse.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = $txtOut.Text
        if ($dlg.ShowDialog() -eq 'OK') {
            $txtOut.Text = $dlg.SelectedPath
            $cfgSave = Read-Config
            if (-not $cfgSave) { $cfgSave = [PSCustomObject]@{} }
            if ($cfgSave.PSObject.Properties.Name -contains 'lastFolder') { $cfgSave.lastFolder = $dlg.SelectedPath }
            else { $cfgSave | Add-Member -NotePropertyName 'lastFolder' -NotePropertyValue $dlg.SelectedPath }
            Save-Config $cfgSave
        }
    } catch { Write-Crash -Where 'btnBrowse.Click' -ErrObj $_ }
})
$form.Controls.Add($btnBrowse)

# ---- Séparateur ----
$sep3             = New-Object System.Windows.Forms.Panel
$sep3.Location    = New-Object System.Drawing.Point(16, 232)
$sep3.Size        = New-Object System.Drawing.Size(690, 1)
$sep3.BackColor   = $cBorder
$sep3.Anchor      = 'Top, Left, Right'
$form.Controls.Add($sep3)

# ---- Bouton Télécharger (accent) ----
$btnGo                   = New-Object System.Windows.Forms.Button
$btnGo.Text              = '  ⬇  Telecharger'
$btnGo.Location          = New-Object System.Drawing.Point(16, 244)
$btnGo.Size              = New-Object System.Drawing.Size(160, 36)
$btnGo.FlatStyle         = 'Flat'
$btnGo.BackColor         = $cAccent
$btnGo.ForeColor         = [System.Drawing.Color]::White
$btnGo.Font              = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnGo.FlatAppearance.BorderSize  = 0
$btnGo.FlatAppearance.MouseOverBackColor = $cAccentHo
$form.Controls.Add($btnGo)

# ---- Bouton Annuler ----
$btnCancel               = New-Object System.Windows.Forms.Button
$btnCancel.Text          = '✕  Annuler'
$btnCancel.Location      = New-Object System.Drawing.Point(186, 244)
$btnCancel.Size          = New-Object System.Drawing.Size(120, 36)
$btnCancel.FlatStyle     = 'Flat'
$btnCancel.BackColor     = $cSurface
$btnCancel.ForeColor     = $cDanger
$btnCancel.FlatAppearance.BorderColor = $cDanger
$btnCancel.FlatAppearance.BorderSize  = 1
$btnCancel.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(50, 248, 81, 73)
$btnCancel.Enabled       = $false
$form.Controls.Add($btnCancel)

# ---- Bouton Ouvrir dossier ----
$btnOpen                 = New-Object System.Windows.Forms.Button
$btnOpen.Text            = '📂  Ouvrir'
$btnOpen.Location        = New-Object System.Drawing.Point(316, 244)
$btnOpen.Size            = New-Object System.Drawing.Size(110, 36)
$btnOpen.FlatStyle       = 'Flat'
$btnOpen.BackColor       = $cSurface
$btnOpen.ForeColor       = $cText
$btnOpen.FlatAppearance.BorderColor = $cBorder
$btnOpen.FlatAppearance.BorderSize  = 1
$btnOpen.FlatAppearance.MouseOverBackColor = $cBorder
$btnOpen.Add_Click({
    try {
        if (Test-Path $txtOut.Text) { Start-Process explorer.exe $txtOut.Text }
    } catch { Write-Crash -Where 'btnOpen.Click' -ErrObj $_ }
})
$form.Controls.Add($btnOpen)

# ---- Label statut ----
$lblStatus               = New-Object System.Windows.Forms.Label
$lblStatus.Location      = New-Object System.Drawing.Point(436, 252)
$lblStatus.Size          = New-Object System.Drawing.Size(270, 20)
$lblStatus.Anchor        = 'Top, Left, Right'
$lblStatus.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
if ($ytdlp -and $ffmpeg) {
    $lblStatus.Text      = "Pret — yt-dlp + ffmpeg OK"
    $lblStatus.ForeColor = $cOk
} else {
    $lblStatus.Text      = "ATTENTION : yt-dlp ou ffmpeg introuvable"
    $lblStatus.ForeColor = $cDanger
}
$form.Controls.Add($lblStatus)

# ---- Progress bar ----
$progressBar             = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location    = New-Object System.Drawing.Point(16, 292)
$progressBar.Size        = New-Object System.Drawing.Size(690, 8)
$progressBar.Minimum     = 0
$progressBar.Maximum     = 100
$progressBar.Value       = 0
$progressBar.Style       = 'Continuous'
$progressBar.Anchor      = 'Top, Left, Right'
$form.Controls.Add($progressBar)

# ---- Bouton logs ----
$btnLogs                 = New-Object System.Windows.Forms.Button
$btnLogs.Text            = 'Logs ▾'
$btnLogs.Location        = New-Object System.Drawing.Point(16, 312)
$btnLogs.Size            = New-Object System.Drawing.Size(100, 24)
$btnLogs.FlatStyle       = 'Flat'
$btnLogs.BackColor       = $cBg
$btnLogs.ForeColor       = $cMuted
$btnLogs.FlatAppearance.BorderColor = $cBorder
$btnLogs.FlatAppearance.BorderSize  = 1
$btnLogs.FlatAppearance.MouseOverBackColor = $cSurface
$form.Controls.Add($btnLogs)

# ---- Zone logs ----
$txtLog                  = New-Object System.Windows.Forms.TextBox
$txtLog.Location         = New-Object System.Drawing.Point(16, 348)
$txtLog.Size             = New-Object System.Drawing.Size(690, 260)
$txtLog.Multiline        = $true
$txtLog.ScrollBars       = 'Vertical'
$txtLog.ReadOnly         = $true
$txtLog.Font             = New-Object System.Drawing.Font('Cascadia Mono,Consolas', 8)
$txtLog.BackColor        = [System.Drawing.Color]::FromArgb(12, 12, 16)
$txtLog.ForeColor        = [System.Drawing.Color]::FromArgb(180, 210, 180)
$txtLog.Anchor           = 'Top, Bottom, Left, Right'
$txtLog.Visible          = $false
$txtLog.BorderStyle      = 'None'
$form.Controls.Add($txtLog)

$btnLogs.Add_Click({
    try {
        if ($txtLog.Visible) {
            $txtLog.Visible  = $false
            $btnLogs.Text    = 'Logs ▾'
            $form.Height     = $collapsedHeight
        } else {
            $txtLog.Visible  = $true
            $btnLogs.Text    = 'Logs ▴'
            $form.Height     = $expandedHeight
        }
    } catch { Write-Crash -Where 'btnLogs.Click' -ErrObj $_ }
})

$btnAbout.Add_Click({
    try {
        $msg = "$AppName v$AppVersion`r`nby $AppAuthor`r`n$AppRepo`r`n`r`nPowered by yt-dlp + ffmpeg."
        [System.Windows.Forms.MessageBox]::Show($msg, 'About', 'OK', 'Information') | Out-Null
    } catch { Write-Crash -Where 'btnAbout.Click' -ErrObj $_ }
})

$btnCancel.Add_Click({
    try {
        if ($script:proc -and -not $script:proc.HasExited) {
            Start-Process 'taskkill' -ArgumentList @('/F', '/T', '/PID', $script:proc.Id.ToString()) -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        }
        $script:running    = $false
        $btnGo.Enabled     = $true
        $btnCancel.Enabled = $false
        $progressBar.Value = 0
        $lblStatus.Text    = 'Annule.'
        $lblStatus.ForeColor = $cWarn
    } catch { Write-Crash -Where 'btnCancel.Click' -ErrObj $_ }
})

# ----------------- Process state -----------------

$script:proc       = $null
$script:logFile    = $null
$script:logPos     = 0
$script:running    = $false

function Append-LogText { param([string]$Text) if ($Text) { $txtLog.AppendText($Text) } }

# ----------------- Timer -----------------

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    try {
        if ($script:logFile -and (Test-Path $script:logFile)) {
            $fs = $null
            try {
                $fs = [System.IO.File]::Open($script:logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                if ($fs.Length -gt $script:logPos) {
                    $fs.Position = $script:logPos
                    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                    $chunk  = $reader.ReadToEnd()
                    $script:logPos = $fs.Position
                    if ($chunk) {
                        Append-LogText $chunk
                        $txtLog.SelectionStart = $txtLog.Text.Length
                        $txtLog.ScrollToCaret()

                        $pctMatches = [regex]::Matches($chunk, '\[download\]\s+(\d+(?:\.\d+)?)%')
                        if ($pctMatches.Count -gt 0) {
                            $last = $pctMatches[$pctMatches.Count - 1]
                            $pct = [int][double]$last.Groups[1].Value
                            if ($pct -lt 0) { $pct = 0 }
                            if ($pct -gt 100) { $pct = 100 }
                            $progressBar.Value = $pct
                        }
                    }
                }
            } finally {
                if ($fs) { $fs.Dispose() }
            }
        }

        if ($script:running -and $script:proc -and $script:proc.HasExited) {
            $script:running    = $false
            $exit = $script:proc.ExitCode
            $btnGo.Enabled     = $true
            $btnCancel.Enabled = $false
            if ($exit -eq 0) {
                $progressBar.Value   = 100
                $lblStatus.Text      = 'Termine  ✔'
                $lblStatus.ForeColor = $cOk
            } else {
                $lblStatus.Text      = "Echec (code $exit)"
                $lblStatus.ForeColor = $cDanger
            }
        }

        # Vérification update (une seule fois, en tâche de fond)
        if ($script:updateJob -and $script:updateJob.State -in @('Completed','Failed','Stopped')) {
            try {
                $result = Receive-Job -Job $script:updateJob -ErrorAction SilentlyContinue
                if ($result -and $result.Latest) {
                    if ((Compare-Version -Va $result.Latest -Vb $AppVersion) -gt 0) {
                        $script:updateAvailable = $result
                        # Bandeau de notif discret
                        $lblStatus.Text      = "Mise a jour $($result.Latest) dispo — cliquer ici"
                        $lblStatus.ForeColor = $cWarn
                        $lblStatus.Cursor = [System.Windows.Forms.Cursors]::Hand
                        $lblStatus.Add_Click({
                            try {
                                if ($script:updateAvailable -and $script:updateAvailable.DownloadUrl) {
                                    Start-Process $script:updateAvailable.DownloadUrl
                                }
                            } catch {}
                        })
                    }
                }
            } catch {}
            Remove-Job -Job $script:updateJob -Force -ErrorAction SilentlyContinue
            $script:updateJob = $null
        }
    } catch {
        Write-Crash -Where 'Timer.Tick' -ErrObj $_
    }
})
$timer.Start()

# ----------------- Click: download -----------------

$btnGo.Add_Click({
    try {
        if ($script:running) { return }

        $cleanedUrl = Clean-YouTubeUrl -RawUrl $cmbUrl.Text
        if ([string]::IsNullOrWhiteSpace($cleanedUrl) -or $cleanedUrl -notmatch '^https?://') {
            [System.Windows.Forms.MessageBox]::Show('URL YouTube invalide. Colle un lien complet.', $AppName, 'OK', 'Warning') | Out-Null
            return
        }
        $cmbUrl.Text = $cleanedUrl

        # Sauvegarde dans l'historique
        Save-HistoryUrl -Url $cleanedUrl
        $cmbUrl.Items.Clear()
        foreach ($h in $historyList) { $cmbUrl.Items.Add($h) | Out-Null }

        if (-not $ytdlp) { [System.Windows.Forms.MessageBox]::Show('yt-dlp introuvable.', $AppName, 'OK', 'Error') | Out-Null; return }
        if (-not $ffmpeg) { [System.Windows.Forms.MessageBox]::Show('ffmpeg introuvable.', $AppName, 'OK', 'Error') | Out-Null; return }

        $out = $txtOut.Text
        if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

        $ytArgs = New-Object System.Collections.Generic.List[string]
        if ($rdoMp3.Checked) {
            $ytArgs.Add('-x'); $ytArgs.Add('--audio-format'); $ytArgs.Add('mp3')
            $ytArgs.Add('--audio-quality'); $ytArgs.Add('0')
        } else {
            $ytArgs.Add('-f'); $ytArgs.Add('bv*+ba/b')
            $ytArgs.Add('--merge-output-format'); $ytArgs.Add('mp4')
        }
        if ($chkPlaylist.Checked) { $ytArgs.Add('--yes-playlist') } else { $ytArgs.Add('--no-playlist') }
        if ($chkSubs.Checked) {
            $ytArgs.Add('--write-subs'); $ytArgs.Add('--write-auto-subs')
            $ytArgs.Add('--sub-langs'); $ytArgs.Add('fr,en')
            $ytArgs.Add('--convert-subs'); $ytArgs.Add('srt')
        }
        $template = if ($chkPlaylist.Checked) {
            Join-Path $out '%(playlist_title)s\%(playlist_index)s - %(title)s.%(ext)s'
        } else {
            Join-Path $out '%(title)s.%(ext)s'
        }
        $ytArgs.Add('--ffmpeg-location'); $ytArgs.Add((Split-Path -Parent $ffmpeg))
        $ytArgs.Add('-o'); $ytArgs.Add($template)
        $ytArgs.Add('--newline'); $ytArgs.Add('--no-mtime')
        $ytArgs.Add('--encoding'); $ytArgs.Add('utf-8')
        $ytArgs.Add($cleanedUrl)

        $argString = ($ytArgs | ForEach-Object { Quote-Arg $_ }) -join ' '

        $script:logFile = Join-Path $env:TEMP ("yt-grab-" + [Guid]::NewGuid().ToString('N') + ".log")
        $script:logPos  = 0
        New-Item -ItemType File -Path $script:logFile -Force | Out-Null

        $cmdLine = "chcp 65001 >nul & `"$ytdlp`" $argString > `"$($script:logFile)`" 2>&1"

        $btnGo.Enabled     = $false
        $btnCancel.Enabled = $true
        $progressBar.Value = 0
        $lblStatus.Text      = 'Telechargement en cours...'
        $lblStatus.ForeColor = $cAccent
        $txtLog.Clear()
        Append-LogText ("> " + $ytdlp + " " + $argString + [Environment]::NewLine + [Environment]::NewLine)

        $script:proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmdLine) -WindowStyle Hidden -PassThru
        $script:running = $true
    } catch {
        Write-Crash -Where 'btnGo.Click' -ErrObj $_
        $btnGo.Enabled     = $true
        $btnCancel.Enabled = $false
        $lblStatus.Text      = "Erreur — voir yt-grab-crash.log"
        $lblStatus.ForeColor = $cDanger
        try { Append-LogText (($_ | Out-String) + [Environment]::NewLine) } catch {}
    }
})

try {
    [void]$form.ShowDialog()
} catch {
    Write-Crash -Where 'ShowDialog' -ErrObj $_
}
$timer.Stop()

if ($script:updateJob) {
    try { Remove-Job -Job $script:updateJob -Force -ErrorAction SilentlyContinue } catch {}
}

if ($script:logFile -and (Test-Path $script:logFile)) {
    try { Remove-Item $script:logFile -Force -ErrorAction SilentlyContinue } catch {}
}
