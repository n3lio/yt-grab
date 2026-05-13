[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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
    param(
        [string]$Name,
        [string]$ExeName
    )

    $config = Read-Config
    if ($config -and $config.$Name -and (Test-Path $config.$Name)) {
        return $config.$Name
    }

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
        if ($config.PSObject.Properties.Name -contains $Name) {
            $config.$Name = $dlg.FileName
        } else {
            $config | Add-Member -NotePropertyName $Name -NotePropertyValue $dlg.FileName
        }
        Save-Config $config
        return $dlg.FileName
    }
    return $null
}

function Quote-Arg {
    param([string]$Arg)
    if ($Arg -match '[\s"]') {
        $escaped = $Arg -replace '"', '\"'
        return '"' + $escaped + '"'
    }
    return $Arg
}

$ytdlp  = Find-Tool -Name 'yt-dlp'  -ExeName 'yt-dlp.exe'
$ffmpeg = Find-Tool -Name 'ffmpeg' -ExeName 'ffmpeg.exe'

if (-not $ytdlp) {
    [System.Windows.Forms.MessageBox]::Show("yt-dlp.exe introuvable. Localise-le dans la fenetre suivante (le chemin sera memorise).", 'My YouTube Downloader', 'OK', 'Information') | Out-Null
    $ytdlp = Prompt-ToolPath -Name 'yt-dlp' -ExeName 'yt-dlp.exe'
}
if (-not $ffmpeg) {
    [System.Windows.Forms.MessageBox]::Show("ffmpeg.exe introuvable. Localise-le dans la fenetre suivante (le chemin sera memorise).", 'My YouTube Downloader', 'OK', 'Information') | Out-Null
    $ffmpeg = Prompt-ToolPath -Name 'ffmpeg' -ExeName 'ffmpeg.exe'
}

$defaultOut = Join-Path $env:USERPROFILE 'Downloads\yt-grab'
if (-not (Test-Path $defaultOut)) { New-Item -ItemType Directory -Path $defaultOut | Out-Null }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'My YouTube Downloader'
$form.Size = New-Object System.Drawing.Size(720, 560)
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
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $txtOut.Text
    if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.SelectedPath }
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
    if (Test-Path $txtOut.Text) { Start-Process explorer.exe $txtOut.Text }
})
$form.Controls.Add($btnOpen)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(285, 213)
$lblStatus.Size = New-Object System.Drawing.Size(400, 20)
$lblStatus.Anchor = 'Top, Left, Right'
if ($ytdlp -and $ffmpeg) {
    $lblStatus.Text = "Prêt. yt-dlp + ffmpeg détectés."
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
} else {
    $lblStatus.Text = "ATTENTION : yt-dlp ou ffmpeg introuvable."
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
}
$form.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 250)
$txtLog.Size = New-Object System.Drawing.Size(670, 250)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 24)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$txtLog.Anchor = 'Top, Bottom, Left, Right'
$form.Controls.Add($txtLog)

$script:logQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120
$timer.Add_Tick({
    $line = $null
    while ($script:logQueue.TryDequeue([ref]$line)) {
        $txtLog.AppendText($line + [Environment]::NewLine)
    }
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
})
$timer.Start()

$script:proc = $null

$btnGo.Add_Click({
    $url = $txtUrl.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('Colle une URL YouTube.', 'My YouTube Downloader', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $ytdlp) {
        [System.Windows.Forms.MessageBox]::Show('yt-dlp introuvable.', 'My YouTube Downloader', 'OK', 'Error') | Out-Null
        return
    }
    if (-not $ffmpeg) {
        [System.Windows.Forms.MessageBox]::Show('ffmpeg introuvable.', 'My YouTube Downloader', 'OK', 'Error') | Out-Null
        return
    }

    $out = $txtOut.Text
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

    $ytArgs = New-Object System.Collections.Generic.List[string]
    if ($rdoMp3.Checked) {
        $ytArgs.AddRange([string[]]@('-x', '--audio-format', 'mp3', '--audio-quality', '0'))
    } else {
        $ytArgs.AddRange([string[]]@('-f', 'bv*+ba/b', '--merge-output-format', 'mp4'))
    }

    if ($chkPlaylist.Checked) { $ytArgs.Add('--yes-playlist') } else { $ytArgs.Add('--no-playlist') }

    if ($chkSubs.Checked) {
        $ytArgs.AddRange([string[]]@('--write-subs', '--write-auto-subs', '--sub-langs', 'fr,en', '--convert-subs', 'srt'))
    }

    $template = if ($chkPlaylist.Checked) {
        Join-Path $out '%(playlist_title)s\%(playlist_index)s - %(title)s.%(ext)s'
    } else {
        Join-Path $out '%(title)s.%(ext)s'
    }

    $ffmpegDir = Split-Path -Parent $ffmpeg
    $ytArgs.AddRange([string[]]@('--ffmpeg-location', $ffmpegDir))
    $ytArgs.AddRange([string[]]@('-o', $template, '--newline', '--no-mtime', '--encoding', 'utf-8', $url))

    $argString = ($ytArgs | ForEach-Object { Quote-Arg $_ }) -join ' '

    $btnGo.Enabled = $false
    $lblStatus.Text = 'Téléchargement en cours...'
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
    $txtLog.Clear()
    $script:logQueue.Enqueue("> $ytdlp $argString")
    $script:logQueue.Enqueue("")

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ytdlp
    $psi.Arguments = $argString
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.WorkingDirectory = $out

    $script:proc = New-Object System.Diagnostics.Process
    $script:proc.StartInfo = $psi
    $script:proc.EnableRaisingEvents = $true

    $onData = {
        param($srcSender, $e)
        if ($null -ne $e.Data) { $script:logQueue.Enqueue([string]$e.Data) }
    }
    $script:proc.add_OutputDataReceived($onData)
    $script:proc.add_ErrorDataReceived($onData)
    $script:proc.add_Exited({
        param($srcSender, $e)
        $exit = $script:proc.ExitCode
        try {
            $form.BeginInvoke([Action]{
                $btnGo.Enabled = $true
                if ($exit -eq 0) {
                    $lblStatus.Text = 'Terminé.'
                    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
                } else {
                    $lblStatus.Text = "Échec (code $exit)."
                    $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
                }
            }) | Out-Null
        } catch {}
    })

    try {
        [void]$script:proc.Start()
        $script:proc.BeginOutputReadLine()
        $script:proc.BeginErrorReadLine()
    } catch {
        $script:logQueue.Enqueue("Erreur lancement : $($_.Exception.Message)")
        $btnGo.Enabled = $true
        $lblStatus.Text = 'Erreur de lancement.'
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
    }
})

[void]$form.ShowDialog()
$timer.Stop()
