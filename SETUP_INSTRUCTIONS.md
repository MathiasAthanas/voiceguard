# VoiceGuard Setup Instructions

This guide explains how to set up and run VoiceGuard on Windows, macOS, and Linux.

VoiceGuard currently uses one main local backend:

```text
Python FastAPI backend on port 8000
```

The same backend handles:

- AI voice enrollment
- AI voice verification
- VoIP signaling with WebSocket first
- HTTP long-polling fallback when WebSocket fails

In the mobile app, use the same URL for both settings:

```text
Signaling Server URL: http://YOUR_PC_IP:8000
AI Backend URL:       http://YOUR_PC_IP:8000
```

## 1. Required Tools

Install these first:

- Git
- Python 3.8 or newer
- Flutter SDK
- Android Studio or Android SDK command-line tools
- A connected Android phone or emulator

Check versions:

```bash
git --version
python --version
flutter --version
flutter doctor
```

On some systems, Python is called `python3` instead of `python`.

## 2. Get The Project

### Fresh Clone

```bash
git clone https://github.com/MathiasAthanas/voiceguard.git
cd voiceguard
```

### If You Already Have The Project

```bash
cd path/to/voiceguard
git pull origin main
```

Windows example:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard
git pull origin main
```

## 3. Backend Setup

The backend lives here:

```text
ai_backend
```

### Windows PowerShell

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\ai_backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

If PowerShell blocks activation, run:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Then activate again:

```powershell
.\.venv\Scripts\Activate.ps1
```

### Windows CMD

```bat
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\ai_backend
python -m venv .venv
.venv\Scripts\activate.bat
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

### macOS

```bash
cd /path/to/voiceguard/ai_backend
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt
```

### Linux

```bash
cd /path/to/voiceguard/ai_backend
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt
```

## 4. Start The Backend

The backend must listen on all network interfaces so phones can reach it.

### Windows PowerShell

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\ai_backend
.\.venv\Scripts\Activate.ps1
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### Windows CMD

```bat
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\ai_backend
.venv\Scripts\activate.bat
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### macOS

```bash
cd /path/to/voiceguard/ai_backend
source .venv/bin/activate
python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### Linux

```bash
cd /path/to/voiceguard/ai_backend
source .venv/bin/activate
python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Backend health check:

```text
http://YOUR_PC_IP:8000/health/
```

## 5. Find Your Computer IP Address

The phone must use your computer's LAN IP address.

### Windows

```powershell
ipconfig
```

Look for:

```text
IPv4 Address
```

Example:

```text
192.168.1.16
```

### macOS

```bash
ipconfig getifaddr en0
```

If that returns nothing, try:

```bash
ifconfig | grep "inet " | grep -v 127.0.0.1
```

### Linux

```bash
hostname -I
```

Or:

```bash
ip addr show
```

## 6. Test From The Phone

Make sure the phone and computer are on the same Wi-Fi.

Open this in the phone browser:

```text
http://YOUR_PC_IP:8000/health/
```

Example:

```text
http://192.168.1.16:8000/health/
```

If this does not open, check:

- Computer and phone are on the same network
- Phone is not on mobile data
- Phone is not on guest Wi-Fi
- VPN is off
- Firewall allows Python
- Backend is running with `--host 0.0.0.0`

## 7. App Setup

The Flutter app lives here:

```text
app
```

### Windows PowerShell

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\app
flutter pub get
flutter doctor
```

### macOS

```bash
cd /path/to/voiceguard/app
flutter pub get
flutter doctor
```

### Linux

```bash
cd /path/to/voiceguard/app
flutter pub get
flutter doctor
```

## 8. Run The App In Debug Mode

Connect an Android phone with USB debugging enabled, then run:

```bash
flutter devices
flutter run
```

From the app settings, set:

```text
Signaling Server URL: http://YOUR_PC_IP:8000
AI Backend URL:       http://YOUR_PC_IP:8000
```

Example:

```text
Signaling Server URL: http://192.168.1.16:8000
AI Backend URL:       http://192.168.1.16:8000
```

## 9. Build A Release APK

This builds one APK that works across old and new supported Android devices.

### Windows PowerShell

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\app
flutter build apk --release --obfuscate --split-debug-info=build\debug-info
```

### macOS

```bash
cd /path/to/voiceguard/app
flutter build apk --release --obfuscate --split-debug-info=build/debug-info
```

### Linux

```bash
cd /path/to/voiceguard/app
flutter build apk --release --obfuscate --split-debug-info=build/debug-info
```

APK output:

```text
app/build/app/outputs/flutter-apk/app-release.apk
```

## 10. Optional Smaller APKs

This creates separate APKs for different CPU architectures.

```bash
flutter build apk --release --obfuscate --split-debug-info=build/debug-info --split-per-abi
```

Outputs are usually:

```text
app-arm64-v8a-release.apk
app-armeabi-v7a-release.apk
app-x86_64-release.apk
```

For most modern Android phones, use:

```text
app-arm64-v8a-release.apk
```

If you want one APK for everyone, use the standard universal APK command instead.

## 11. Copy-Paste Helper Scripts

These scripts are optional. They make it easier for non-technical users to start the backend.

### Windows: `start_backend.ps1`

Save this file in the project root as:

```text
start_backend.ps1
```

```powershell
$ErrorActionPreference = "Stop"
Set-Location "$PSScriptRoot\ai_backend"

if (!(Test-Path ".venv")) {
    python -m venv .venv
}

.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Run it:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard
.\start_backend.ps1
```

### Windows: `build_apk.ps1`

Save this file in the project root as:

```text
build_apk.ps1
```

```powershell
$ErrorActionPreference = "Stop"
Set-Location "$PSScriptRoot\app"
flutter pub get
flutter build apk --release --obfuscate --split-debug-info=build\debug-info
Write-Host "APK built at: $PWD\build\app\outputs\flutter-apk\app-release.apk"
```

Run it:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard
.\build_apk.ps1
```

### macOS/Linux: `start_backend.sh`

Save this file in the project root as:

```text
start_backend.sh
```

```bash
#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/ai_backend"

if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi

source .venv/bin/activate
python3 -m pip install -r requirements.txt
python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Make it executable and run:

```bash
chmod +x start_backend.sh
./start_backend.sh
```

### macOS/Linux: `build_apk.sh`

Save this file in the project root as:

```text
build_apk.sh
```

```bash
#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/app"
flutter pub get
flutter build apk --release --obfuscate --split-debug-info=build/debug-info
echo "APK built at: $(pwd)/build/app/outputs/flutter-apk/app-release.apk"
```

Make it executable and run:

```bash
chmod +x build_apk.sh
./build_apk.sh
```

## 12. Troubleshooting

### Phone Cannot Reach Backend

Check the backend is running:

```text
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Then test from phone browser:

```text
http://YOUR_PC_IP:8000/health/
```

If it fails:

- Check same Wi-Fi
- Disable VPN
- Disable mobile data temporarily
- Avoid guest Wi-Fi
- Allow Python through firewall
- Use the correct PC IP

### App Connects On One Phone But Not Another

Set both URLs manually in the app:

```text
http://YOUR_PC_IP:8000
```

Then tap the test buttons in Settings.

If WebSocket fails, the app should fall back to HTTP long polling automatically.

### Old Settings Keep Coming Back

Clear app storage on the Android phone:

```text
Android Settings -> Apps -> VoiceGuard -> Storage -> Clear data
```

Then reopen the app and enter the URLs again.

### Python Package Install Fails

Upgrade pip:

```bash
python -m pip install --upgrade pip
```

or:

```bash
python3 -m pip install --upgrade pip
```

Then retry:

```bash
pip install -r requirements.txt
```

### Flutter Build Fails

Run:

```bash
flutter clean
flutter pub get
flutter doctor
```

Then rebuild:

```bash
flutter build apk --release --obfuscate --split-debug-info=build/debug-info
```

On Windows PowerShell, use:

```powershell
flutter build apk --release --obfuscate --split-debug-info=build\debug-info
```

## 13. Legacy Node Server

The old Node signaling server is still in:

```text
server
```

It is kept for reference, but the recommended local setup does not require it.

Use the FastAPI backend on port `8000` unless you specifically need to test the older Socket.IO flow.

## 14. Daily Development Checklist

1. Pull latest code:

```bash
git pull origin main
```

2. Start backend:

```bash
cd ai_backend
source .venv/bin/activate
python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Windows PowerShell:

```powershell
cd ai_backend
.\.venv\Scripts\Activate.ps1
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

3. Confirm phone can open:

```text
http://YOUR_PC_IP:8000/health/
```

4. Run app:

```bash
cd app
flutter run
```

5. Set app URLs:

```text
http://YOUR_PC_IP:8000
```

6. Test:

- enrollment
- backend health
- signaling connection
- VoIP call
- voice verification during call
