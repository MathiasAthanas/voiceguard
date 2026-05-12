from fastapi import APIRouter
from app.utils.embedding_utils import list_enrolled_contacts

router = APIRouter()


@router.get("/")
async def health_check():
    enrolled = list_enrolled_contacts()
    return {
        "status": "ok",
        "service": "VoiceGuard AI Backend",
        "enrolled_contacts": len(enrolled),
        "contacts": enrolled,
    }
