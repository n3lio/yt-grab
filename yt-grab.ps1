[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Find-Tool {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$ytdlp = Find-Tool 'yt-dlp'
$ffmpeg = Find-Tool 'ffmpeg'

$defaultOut = Join-Path $env:USERPROFILE 'Downloads\yt-grab'
if (-not (Test-Path $defaultOut)) { New-Item -ItemType Directory -Path $defaultOut | Out-Null }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'yt-grab'
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
$btnBrowse.Text = 'Parcourir…'
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
$lblStatus.Text = if ($ytdlp -and $ffmpeg) { "Prêt. yt-dlp + ffmpeg détectés." } else { "ATTENTION : yt-dlp ou ffmpeg introuvable dans PATH." }
$lblStatus.ForeColor = if ($ytdlp -and $ffmpeg) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }
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

function Append-Log {
    param([string]$Text)
    if ($txtLog.InvokeRequired) {
        $txtLog.Invoke([Action[string]]{ param($t) Append-Log $t }, $Text)
        return
    }
    $txtLog.AppendText($Text + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
}

$btnGo.Add_Click({
    $url = $txtUrl.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show('Colle une URL YouTube.', 'yt-grab', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $ytdlp) {
        [System.Windows.Forms.MessageBox]::Show('yt-dlp introuvable dans PATH.', 'yt-grab', 'OK', 'Error') | Out-Null
        return
    }
    if (-not $ffmpeg) {
        [System.Windows.Forms.MessageBox]::Show('ffmpeg introuvable dans PATH.', 'yt-grab', 'OK', 'Error') | Out-Null
        return
    }

    $out = $txtOut.Text
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

    $args = @()
    if ($rdoMp3.Checked) {
        $args += @('-x', '--audio-format', 'mp3', '--audio-quality', '0')
    } else {
        $args += @('-f', 'bv*+ba/b', '--merge-output-format', 'mp4')
    }

    if (-not $chkPlaylist.Checked) { $args += '--no-playlist' } else { $args += '--yes-playlist' }

    if ($chkSubs.Checked) {
        $args += @('--write-subs', '--write-auto-subs', '--sub-langs', 'fr,en', '--convert-subs', 'srt')
    }

    $template = if ($chkPlaylist.Checked) {
        Join-Path $out '%(playlist_title)s/%(playlist_index)s - %(title)s.%(ext)s'
    } else {
        Join-Path $out '%(title)s.%(ext)s'
    }
    $args += @('-o', $template, '--newline', '--no-mtime', $url)

    $btnGo.Enabled = $false
    $lblStatus.Text = 'Téléchargement en cours…'
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
    $txtLog.Clear()
    Append-Log "> yt-dlp $($args -join ' ')"
    Append-Log ""

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ytdlp
    foreach ($a in $args) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true

    $onData = {
        param($s, $e)
        if ($e.Data) { Append-Log $e.Data }
    }
    $proc.add_OutputDataReceived($onData)
    $proc.add_ErrorDataReceived($onData)
    $proc.add_Exited({
        param($s, $e)
        $form.Invoke([Action]{
            $btnGo.Enabled = $true
            if ($proc.ExitCode -eq 0) {
                $lblStatus.Text = 'Terminé.'
                $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            } else {
                $lblStatus.Text = "Échec (code $($proc.ExitCode))."
                $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
            }
        }) | Out-Null
    })

    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
})

[void]$form.ShowDialog()
