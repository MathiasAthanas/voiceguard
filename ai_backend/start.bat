@echo off
cd /d "%~dp0"
echo Starting VoiceGuard AI Backend...
echo Listening on: http://192.168.1.10:8000
echo.
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
pause
