# yt-grab

Petite app Windows pour télécharger des vidéos / audio YouTube sans toucher au terminal.

## Prérequis

- Windows 10 ou 11
- `yt-dlp` accessible dans le `PATH`
- `ffmpeg` accessible dans le `PATH`

Vérifier dans une fenêtre PowerShell :

```powershell
yt-dlp --version
ffmpeg -version
```

Si l'une des deux commandes ne répond pas, ajouter l'exécutable au `PATH`.

## Installation

```powershell
git clone https://github.com/n3lio/yt-grab.git
cd yt-grab
```

## Utilisation

Double-cliquer sur **`launch.bat`**. Une petite fenêtre Windows s'ouvre :

1. Coller l'URL YouTube (vidéo ou playlist).
2. Choisir **MP4** (vidéo + audio max qualité) ou **MP3** (audio seul, 320 kbps).
3. Cocher *Télécharger toute la playlist* si l'URL pointe sur une playlist et que tu veux tout récupérer.
4. Cocher *Inclure sous-titres* pour récupérer les `.srt` (français + anglais).
5. Choisir le dossier de destination (par défaut `Downloads\yt-grab`).
6. Cliquer **Télécharger**. Les logs `yt-dlp` défilent en bas.

## Mise à jour

```powershell
cd yt-grab
git pull
```
