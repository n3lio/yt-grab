# yt-grab

Petite app Windows pour télécharger des vidéos / audio YouTube sans toucher au terminal.

## Prérequis

- Windows 10 ou 11
- `yt-dlp.exe` quelque part sur la machine (typiquement `Downloads\yt-dlp\yt-dlp.exe`)
- `ffmpeg.exe` accessible — soit dans le `PATH` (ex: installé via `winget install Gyan.FFmpeg`), soit dans un dossier connu

Le script cherche ces exécutables dans cet ordre :
1. Chemin mémorisé dans `yt-grab.config.json` (créé après une première sélection manuelle)
2. `PATH` du système
3. Emplacements habituels : `Downloads\yt-dlp\`, `Documents\yt-dlp\`, `Desktop\yt-dlp\`, à côté du script
4. Scan récursif (depth 3) de `Downloads`, `Documents`, `Desktop`
5. Si toujours introuvable → fenêtre "Localise yt-dlp.exe", le chemin choisi est mémorisé pour les prochains lancements

Donc tu peux déplacer le dossier `yt-dlp` librement entre Downloads / Documents / Desktop sans rien reconfigurer.

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

## Compiler en .exe (optionnel)

Tu peux générer un vrai `yt-grab.exe` double-cliquable, avec icône custom et métadonnées Windows propres (Propriétés → Détails) :

1. Pose un fichier **`yt-grab.ico`** à côté du script (icône multi-résolution 16/32/48/256). [icoconvert.com](https://icoconvert.com) convertit un PNG en .ico en quelques clics.
2. Lance le build :

```powershell
.\build.ps1
```

Au premier lancement, il installe automatiquement le module `ps2exe` (Scope CurrentUser, pas besoin d'admin). Le script lit la version, le nom et l'auteur directement depuis `yt-grab.ps1` pour rester synchro. Si tu veux lancer l'exe juste après le build :

```powershell
.\build.ps1 -Run
```

L'exe est créé à côté du `.ps1` (~150 KB). Tu peux l'épingler à la barre des tâches, créer un raccourci sur le Bureau, etc.
