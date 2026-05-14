# VoiceGuard Local Networking Improvements

This document explains what changed, why it changed, and how to run the project after pulling the latest code.

## What Changed

Before this update, VoiceGuard used two local servers:

- Python FastAPI AI backend on port `8000`
- Node Socket.IO signaling server on port `3000` or `9000`

The AI backend was reachable from the phones, but some phones could not reach the Node signaling server through WebSocket. That meant voice verification could work, while VoIP signaling failed.

After this update, local development uses one main server:

- Python FastAPI backend on port `8000`

The Python backend now handles both:

- AI voice enrollment and verification
- VoIP signaling for calls

## Why This Changed

Some phones can reach normal HTTP endpoints but fail when the app tries to open a WebSocket connection to the local Node server.

The new setup tries the best transport first:

1. The app tries FastAPI WebSocket signaling.
2. If WebSocket fails, the app automatically falls back to HTTP long polling.

This keeps calls fast on devices where WebSocket works and keeps calls functional on devices where WebSocket fails.

## New Local URLs

Use the same FastAPI URL for both settings in the app:

```text
Signaling Server URL: http://YOUR_PC_IP:8000
AI Backend URL:       http://YOUR_PC_IP:8000
```

Example:

```text
Signaling Server URL: http://192.168.1.16:8000
AI Backend URL:       http://192.168.1.16:8000
```

The Node server is no longer required for local signaling after this update.

## After Git Pull

From the repo folder:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard
git pull
```

## Install Python Backend Dependencies

From the repo folder:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\ai_backend
python -m pip install -r requirements.txt
```

If your machine uses `py` instead of `python`, use:

```powershell
py -m pip install -r requirements.txt
```

## Install Flutter App Dependencies

From the Flutter app folder:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\app
flutter pub get
```

## Start The Python Backend

From the backend folder:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\ai_backend
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Or with `py`:

```powershell
py -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

## Find Your PC IP Address

Run:

```powershell
ipconfig
```

Look for the Wi-Fi IPv4 address. It usually looks like:

```text
192.168.1.16
```

Then use:

```text
http://192.168.1.16:8000
```

inside the app settings.

## Test The Backend From A Phone

Open this in the phone browser:

```text
http://YOUR_PC_IP:8000/health/
```

Example:

```text
http://192.168.1.16:8000/health/
```

If the phone can open that page, the app should be able to reach the backend.

## App Settings

In VoiceGuard settings, use the same URL for both fields:

```text
Signaling Server URL: http://YOUR_PC_IP:8000
AI Backend URL:       http://YOUR_PC_IP:8000
```

If the app was installed before this change, clear app storage or manually update both fields. Old saved settings may still point to the Node server port.

## Important Notes

- All phones and the PC must be on the same local network.
- If a phone is on guest Wi-Fi, VPN, or mobile data, it may not reach the PC.
- Windows Firewall must allow Python on the current network profile.
- The Node server is no longer needed for local signaling.
- WebRTC media still goes directly between phones; the backend only exchanges call setup messages.
