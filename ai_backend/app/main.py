from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
import os

from app.api import enroll, verify, health

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

# Create required directories on startup
@app.on_event("startup")
async def startup_event():
    os.makedirs(os.getenv("VOICEPRINTS_DIR", "voiceprints"), exist_ok=True)
    os.makedirs(os.getenv("WEIGHTS_DIR", "weights"), exist_ok=True)
    print("VoiceGuard AI Backend started")
    print(f"Voiceprints directory: {os.getenv('VOICEPRINTS_DIR', 'voiceprints')}")
