@echo off
echo Adding Windows Firewall rule for VoiceGuard backend (port 8000)...
netsh advfirewall firewall add rule name="VoiceGuard Backend Port 8000" dir=in action=allow protocol=TCP localport=8000
echo.
echo Done. You can close this window.
pause
