# 🛠 Scripts Collection by razzledazzlei

This repo contains various automation and utility scripts for Windows, including:

## 🔧 Scripts Overview

| Script File                  | Description                                      |
|-----------------------------|--------------------------------------------------|
| `BrinkTerm.py`              | Configures network settings for registers        |
| `backup_scripts.ps1`        | Creates nightly ZIP backups of `C:\Scripts`      |
| `UpdateWIM.ps1`             | Automates WIM updates for imaging                |
| `import_requests.py`        | Helper for downloading and parsing requests      |
| `BluetoothButtonTest.ahk`   | Tests Bluetooth button inputs (AutoHotkey)       |

## 📦 Backup Strategy

- All scripts are backed up nightly to Google Drive as timestamped ZIPs
- Old backups (30+ days) are automatically deleted

## 📁 Repo Structure

```
C:\Scripts
├── networking
├── automation
├── logging
├── web
├── archive
├── misc
├── dist
├── build
└── README.md
```