import logging

from fastapi import APIRouter, UploadFile, File, Form, HTTPException
from app.services.verification_service import get_verification_service
from app.stats_store import get_stats_store

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/")
async def verify_voice(
    contact_id: str = Form(...),
    audio_file: UploadFile = File(...),
    source_quality: str = Form("high"),
    audio_role: str = Form("remote_speaker"),
    media_source: str = Form("unknown"),
):
    """
    Verify if the audio matches the enrolled contact.
    Runs anti-spoofing then speaker verification.

    Returns 200 for all normal verdicts including 'silent' (no speech detected).
    Returns 404 only when the contact has no enrolled voiceprint.
    """
    if not contact_id.strip():
        raise HTTPException(status_code=400, detail="contact_id cannot be empty")

    audio_bytes = await audio_file.read()
    if len(audio_bytes) == 0:
        raise HTTPException(status_code=400, detail="Empty audio file")

    service = get_verification_service()
    try:
        result = service.verify(
            contact_id.strip(),
            audio_bytes,
            audio_role=audio_role.strip() or "remote_speaker",
            media_source=media_source.strip() or source_quality.strip() or "unknown",
        )
    except Exception as exc:
        logger.exception("Unexpected error during verification for contact '%s'", contact_id)
        raise HTTPException(status_code=500, detail=f"Verification error: {exc}") from exc

    # 404 only when no voiceprint exists — all other cases (silent, uncertain, etc.)
    # are valid verdicts and should return 200 so the Flutter client can handle them.
    if result.get("verdict") == "not_enrolled":
        raise HTTPException(
            status_code=404,
            detail=result.get("error", f"No voiceprint enrolled for: {contact_id}"),
        )

    await get_stats_store().record_verification(contact_id.strip(), result)
    return result
