[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ----------------- App metadata (mettre à jour à chaque release) -----------------

$AppName    = 'My YouTube Downloader'
$AppVersion = '1.1.0'
$AppAuthor  = 'n3lio'
$AppRepo    = 'https://github.com/n3lio/yt-grab'
$AppChangelog = @"
v1.1.0 — Logs cachés par défaut, barre de progression, nettoyage automatique
        de l'URL collée, bouton À propos.
v1.0.1 — Lancement robuste via cmd.exe + log fichier (corrige les crashs au clic).
v1.0.0 — Version initiale : MP4/MP3, playlist, sous-titres, dossier de sortie.
"@

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$crashLog  = Join-Path $scriptDir 'yt-grab-crash.log'

function Write-Crash {
    param([string]$Where, $ErrObj)
    $msg = "[$(Get-Date -Format o)] $Where`n"
    if ($ErrObj) {
        $msg += ($ErrObj | Out-String)
        if ($ErrObj.ScriptStackTrace) { $msg += "`n$($ErrObj.ScriptStackTrace)`n" }
        if ($ErrObj.Exception) { $msg += "`n$($ErrObj.Exception.ToString())`n" }
    }
    $msg += "`n----`n"
    Add-Content -Path $crashLog -Value $msg -Encoding UTF8
}

trap {
    Write-Crash -Where 'TOP-LEVEL trap' -ErrObj $_
    continue
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Crash -Where 'Add-Type' -ErrObj $_
    throw
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

function Find-Tool {
    param([string]$Name, [string]$ExeName)

    $config = Read-Config
    if ($config -and $config.$Name -and (Test-Path $config.$Name)) { return $config.$Name }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @(
        $scriptDir,
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Downloads\yt-dlp'),
        (Join-Path $env:USERPROFILE 'Documents\yt-dlp'),
        (Join-Path $env:USERPROFILE 'Desktop\yt-dlp'),
        (Join-Path $env:USERPROFILE 'Downloads\ffmpeg\bin'),
        (Join-Path $env:USERPROFILE 'Documents\ffmpeg\bin'),
        'C:\ffmpeg\bin',
        'C:\Program Files\ffmpeg\bin'
    )
    foreach ($root in $roots) {
        $candidate = Join-Path $root $ExeName
        if (Test-Path $candidate) { return $candidate }
    }

    foreach ($root in @($env:USERPROFILE + '\Downloads', $env:USERPROFILE + '\Documents', $env:USERPROFILE + '\Desktop')) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter $ExeName -Recurse -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Prompt-ToolPath {
    param([string]$Name, [string]$ExeName)
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Localise $ExeName"
    $dlg.Filter = "$ExeName|$ExeName"
    $dlg.InitialDirectory = Join-Path $env:USERPROFILE 'Downloads'
    if ($dlg.ShowDialog() -eq 'OK') {
        $config = Read-Config
        if (-not $config) { $config = [PSCustomObject]@{} }
        if ($config.PSObject.Properties.Name -contains $Name) { $config.$Name = $dlg.FileName }
        else { $config | Add-Member -NotePropertyName $Name -NotePropertyValue $dlg.FileName }
        Save-Config $config
        return $dlg.FileName
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
    param([string]$Input)
    if (-not $Input) { return '' }
    $s = $Input.Trim()

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

    $host = $uri.Host.ToLower()
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

    if ($host -like '*youtu.be*') {
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

$ytdlp  = Find-Tool -Name 'yt-dlp'  -ExeName 'yt-dlp.exe'
$ffmpeg = Find-Tool -Name 'ffmpeg' -ExeName 'ffmpeg.exe'

if (-not $ytdlp) {
    [System.Windows.Forms.MessageBox]::Show("yt-dlp.exe introuvable. Localise-le dans la fenetre suivante (le chemin sera memorise).", $AppName, 'OK', 'Information') | Out-Null
    $ytdlp = Prompt-ToolPath -Name 'yt-dlp' -ExeName 'yt-dlp.exe'
}
if (-not $ffmpeg) {
    [System.Windows.Forms.MessageBox]::Show("ffmpeg.exe introuvable. Localise-le dans la fenetre suivante (le chemin sera memorise).", $AppName, 'OK', 'Information') | Out-Null
    $ffmpeg = Prompt-ToolPath -Name 'ffmpeg' -ExeName 'ffmpeg.exe'
}

$defaultOut = Join-Path $env:USERPROFILE 'Downloads\yt-grab'
if (-not (Test-Path $defaultOut)) { New-Item -ItemType Directory -Path $defaultOut | Out-Null }

# ----------------- UI dimensions -----------------

$collapsedHeight = 360
$expandedHeight  = 600

# ----------------- UI build -----------------

$form = New-Object System.Windows.Forms.Form
$form.Text = $AppName
$form.Size = New-Object System.Drawing.Size(720, $collapsedHeight)
$form.MinimumSize = New-Object System.Drawing.Size(680, $collapsedHeight)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblUrl = New-Object System.Windows.Forms.Label
$lblUrl.Text = 'URL YouTube (vidéo ou playlist) :'
$lblUrl.Location = New-Object System.Drawing.Point(15, 15)
$lblUrl.AutoSize = $true
$form.Controls.Add($lblUrl)

$txtUrl = New-Object System.Windows.Forms.TextBox
$txtUrl.Location = New-Object System.Drawing.Point(15, 35)
$txtUrl.Size = New-Object System.Drawing.Size(670, 25)
$txtUrl.Anchor = 'Top, Left, Right'
$form.Controls.Add($txtUrl)

$grpFormat = New-Object System.Windows.Forms.GroupBox
$grpFormat.Text = 'Format'
$grpFormat.Location = New-Object System.Drawing.Point(15, 70)
$grpFormat.Size = New-Object System.Drawing.Size(330, 70)
$rdoMp4 = New-Object System.Windows.Forms.RadioButton
$rdoMp4.Text = 'MP4 — qualité max (vidéo + audio)'
$rdoMp4.Location = New-Object System.Drawing.Point(15, 20)
$rdoMp4.AutoSize = $true
$rdoMp4.Checked = $true
$grpFormat.Controls.Add($rdoMp4)
$rdoMp3 = New-Object System.Windows.Forms.RadioButton
$rdoMp3.Text = 'MP3 — audio seul (320 kbps)'
$rdoMp3.Location = New-Object System.Drawing.Point(15, 42)
$rdoMp3.AutoSize = $true
$grpFormat.Controls.Add($rdoMp3)
$form.Controls.Add($grpFormat)

$grpOpts = New-Object System.Windows.Forms.GroupBox
$grpOpts.Text = 'Options'
$grpOpts.Location = New-Object System.Drawing.Point(355, 70)
$grpOpts.Size = New-Object System.Drawing.Size(330, 70)
$chkPlaylist = New-Object System.Windows.Forms.CheckBox
$chkPlaylist.Text = 'Télécharger toute la playlist (si URL playlist)'
$chkPlaylist.Location = New-Object System.Drawing.Point(15, 20)
$chkPlaylist.AutoSize = $true
$grpOpts.Controls.Add($chkPlaylist)
$chkSubs = New-Object System.Windows.Forms.CheckBox
$chkSubs.Text = 'Inclure sous-titres si dispo (.srt)'
$chkSubs.Location = New-Object System.Drawing.Point(15, 42)
$chkSubs.AutoSize = $true
$grpOpts.Controls.Add($chkSubs)
$form.Controls.Add($grpOpts)

$lblOut = New-Object System.Windows.Forms.Label
$lblOut.Text = 'Dossier de destination :'
$lblOut.Location = New-Object System.Drawing.Point(15, 150)
$lblOut.AutoSize = $true
$form.Controls.Add($lblOut)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(15, 170)
$txtOut.Size = New-Object System.Drawing.Size(580, 25)
$txtOut.Text = $defaultOut
$txtOut.Anchor = 'Top, Left, Right'
$form.Controls.Add($txtOut)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Parcourir...'
$btnBrowse.Location = New-Object System.Drawing.Point(605, 168)
$btnBrowse.Size = New-Object System.Drawing.Size(80, 26)
$btnBrowse.Anchor = 'Top, Right'
$btnBrowse.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = $txtOut.Text
        if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.SelectedPath }
    } catch { Write-Crash -Where 'btnBrowse.Click' -ErrObj $_ }
})
$form.Controls.Add($btnBrowse)

$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = 'Télécharger'
$btnGo.Location = New-Object System.Drawing.Point(15, 205)
$btnGo.Size = New-Object System.Drawing.Size(120, 32)
$btnGo.BackColor = [System.Drawing.Color]::FromArgb(40, 120, 200)
$btnGo.ForeColor = [System.Drawing.Color]::White
$btnGo.FlatStyle = 'Flat'
$form.Controls.Add($btnGo)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Ouvrir le dossier'
$btnOpen.Location = New-Object System.Drawing.Point(145, 205)
$btnOpen.Size = New-Object System.Drawing.Size(130, 32)
$btnOpen.Add_Click({
    try {
        if (Test-Path $txtOut.Text) { Start-Process explorer.exe $txtOut.Text }
    } catch { Write-Crash -Where 'btnOpen.Click' -ErrObj $_ }
})
$form.Controls.Add($btnOpen)

$btnAbout = New-Object System.Windows.Forms.Button
$btnAbout.Text = '?'
$btnAbout.Size = New-Object System.Drawing.Size(32, 32)
$btnAbout.Location = New-Object System.Drawing.Point(653, 205)
$btnAbout.Anchor = 'Top, Right'
$btnAbout.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnAbout)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(285, 213)
$lblStatus.Size = New-Object System.Drawing.Size(360, 20)
$lblStatus.Anchor = 'Top, Left, Right'
if ($ytdlp -and $ffmpeg) {
    $lblStatus.Text = "Prêt. yt-dlp + ffmpeg détectés."
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
} else {
    $lblStatus.Text = "ATTENTION : yt-dlp ou ffmpeg introuvable."
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
}
$form.Controls.Add($lblStatus)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 250)
$progressBar.Size = New-Object System.Drawing.Size(670, 18)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$progressBar.Style = 'Continuous'
$progressBar.Anchor = 'Top, Left, Right'
$form.Controls.Add($progressBar)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = 'Afficher les logs ▾'
$btnLogs.Location = New-Object System.Drawing.Point(15, 280)
$btnLogs.Size = New-Object System.Drawing.Size(160, 26)
$btnLogs.FlatStyle = 'Flat'
$form.Controls.Add($btnLogs)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 315)
$txtLog.Size = New-Object System.Drawing.Size(670, 240)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 24)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$txtLog.Anchor = 'Top, Bottom, Left, Right'
$txtLog.Visible = $false
$form.Controls.Add($txtLog)

$btnLogs.Add_Click({
    try {
        if ($txtLog.Visible) {
            $txtLog.Visible = $false
            $btnLogs.Text = 'Afficher les logs ▾'
            $form.Height = $collapsedHeight
        } else {
            $txtLog.Visible = $true
            $btnLogs.Text = 'Masquer les logs ▴'
            $form.Height = $expandedHeight
        }
    } catch { Write-Crash -Where 'btnLogs.Click' -ErrObj $_ }
})

$btnAbout.Add_Click({
    try {
        $msg = @"
$AppName  v$AppVersion

Auteur : $AppAuthor
Repo   : $AppRepo

Mini app Windows pour télécharger des vidéos / audio YouTube
sans toucher au terminal. Utilise yt-dlp + ffmpeg.

Changelog :
$AppChangelog
"@
        [System.Windows.Forms.MessageBox]::Show($msg, "À propos — $AppName", 'OK', 'Information') | Out-Null
    } catch { Write-Crash -Where 'btnAbout.Click' -ErrObj $_ }
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
            $script:running = $false
            $exit = $script:proc.ExitCode
            $btnGo.Enabled = $true
            if ($exit -eq 0) {
                $progressBar.Value = 100
                $lblStatus.Text = 'Terminé.'
                $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            } else {
                $lblStatus.Text = "Échec (code $exit)."
                $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
            }
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

        $cleanedUrl = Clean-YouTubeUrl $txtUrl.Text
        if ([string]::IsNullOrWhiteSpace($cleanedUrl) -or $cleanedUrl -notmatch '^https?://') {
            [System.Windows.Forms.MessageBox]::Show('URL YouTube invalide. Colle un lien complet.', $AppName, 'OK', 'Warning') | Out-Null
            return
        }
        $txtUrl.Text = $cleanedUrl

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

        $btnGo.Enabled = $false
        $progressBar.Value = 0
        $lblStatus.Text = 'Téléchargement en cours...'
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
        $txtLog.Clear()
        Append-LogText ("> " + $ytdlp + " " + $argString + [Environment]::NewLine + [Environment]::NewLine)

        $script:proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmdLine) -WindowStyle Hidden -PassThru
        $script:running = $true
    } catch {
        Write-Crash -Where 'btnGo.Click' -ErrObj $_
        $btnGo.Enabled = $true
        $lblStatus.Text = "Erreur — voir yt-grab-crash.log"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
        try { Append-LogText (($_ | Out-String) + [Environment]::NewLine) } catch {}
    }
})

try {
    [void]$form.ShowDialog()
} catch {
    Write-Crash -Where 'ShowDialog' -ErrObj $_
}
$timer.Stop()

if ($script:logFile -and (Test-Path $script:logFile)) {
    try { Remove-Item $script:logFile -Force -ErrorAction SilentlyContinue } catch {}
}
