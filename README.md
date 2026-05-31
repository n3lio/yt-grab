# YouTube Grabber by n3lio

Télécharge des vidéos et musiques YouTube en double-clic. Pas de terminal, pas de prérequis à installer manuellement.

## Installation

1. Va sur la page [**Releases**](https://github.com/n3lio/yt-grab/releases/latest)
2. Télécharge `yt-grab-X.X.X-setup.exe`
3. Double-clique, suis l'installeur (moins de 30 secondes)
4. Lance **YouTube Grabber** depuis le Bureau ou le Menu Démarrer

> **yt-dlp** et **ffmpeg** sont téléchargés automatiquement au premier lancement. Aucune installation manuelle requise.

## Prérequis

- Windows 10 ou 11

C'est tout.

## Utilisation

1. Colle une URL YouTube dans le champ en haut (vidéo, playlist, Shorts) — ou glisse-dépose depuis le navigateur
2. Choisis le format : **MP3** (320k), **WAV** (lossless) ou **MP4** (meilleure qualité)
3. Options : playlist complète, sous-titres, métadonnées + cover art
4. Clique **+ Ajouter** ou appuie sur **Entrée**
5. Clique **⬇ Tout télécharger**

Tu peux ajouter plusieurs URLs avant de lancer — la file d'attente traite tout dans l'ordre, avec progression et vitesse en temps réel.

## Fonctionnalités

- File d'attente multi-items avec thumbnail, progression et vitesse
- Preview automatique (titre, chaîne, durée, miniature) dès que tu colles une URL
- Historique des 10 dernières URLs
- Drag & drop depuis le navigateur
- Réordonnancement de la file (▲▼)
- Reprise automatique si l'app crashe
- Mise à jour yt-dlp en un clic depuis l'app
- Notification Windows à la fin des téléchargements
- Désinstallation propre via Programmes et fonctionnalités

## Stack

PowerShell 5.1 + WPF, compilé en `.exe` via [ps2exe](https://github.com/MScholtes/PS2EXE). Installeur [Inno Setup 6](https://jrsoftware.org/isinfo.php). Build et release automatisés via GitHub Actions.
