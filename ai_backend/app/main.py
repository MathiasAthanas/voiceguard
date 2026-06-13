from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
import os
import socket

import app.database as db
from app.api import enroll, verify, health, signaling, dashboard
from app.stats_store import get_stats_store

load_dotenv()

app = FastAPI(
    title="VoiceGuard AI Backend",
    description="Voice biometric verification and anti-spoofing API",
    version="1.0.0",
)

# Allow all origins for local network use
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Routers
app.include_router(health.router, prefix="/health", tags=["Health"])
app.include_router(enroll.router, prefix="/enroll", tags=["Enrollment"])
app.include_router(verify.router, prefix="/verify", tags=["Verification"])
app.include_router(signaling.router, prefix="/signaling", tags=["Signaling"])
app.include_router(dashboard.router, prefix="/dashboard", tags=["Dashboard"])

# Create required directories on startup
@app.on_event("startup")
async def startup_event():
    os.makedirs(os.getenv("VOICEPRINTS_DIR", "voiceprints"), exist_ok=True)
    os.makedirs(os.getenv("WEIGHTS_DIR", "weights"), exist_ok=True)
    db.init_db()
    await get_stats_store().initialize()
    host = os.getenv("HOST", "0.0.0.0")
    port = os.getenv("PORT", "8000")
    print("VoiceGuard AI Backend started")
    print(f"Voiceprints directory: {os.getenv('VOICEPRINTS_DIR', 'voiceprints')}")
    print(f"Backend listening on: http://{host}:{port}")
    print("Use this backend URL in the mobile app:")
    for url in _network_urls(port):
        print(f"  {url}")
    print("Dashboard URLs:")
    for url in _network_urls(port, path="/dashboard/"):
        print(f"  {url}")


def _network_urls(port: str, path: str = "") -> list:
    urls = []
    try:
        hostname = socket.gethostname()
        addresses = socket.gethostbyname_ex(hostname)[2]
    except Exception:
        addresses = []

    seen = set()
    for address in ["127.0.0.1", *addresses]:
        if not address or address.startswith("169.254.") or address in seen:
            continue
        seen.add(address)
        urls.append(f"http://{address}:{port}{path}")
    return urls
