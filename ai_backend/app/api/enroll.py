from fastapi import APIRouter, UploadFile, File, Form, HTTPException
from typing import List
from app.services.enrollment_service import get_enrollment_service
from app.utils.embedding_utils import (
    voiceprint_exists,
    delete_voiceprint,
    list_enrolled_contacts,
)

router = APIRouter()


@router.post("/")
async def enroll_contact(
    contact_id: str = Form(...),
    source_quality: str = Form("high"),
    audio_files: List[UploadFile] = File(...),
):
    """
    Enroll a contact's voice.
    Accepts one or multiple audio files.
    """
    if not contact_id.strip():
        raise HTTPException(status_code=400, detail="contact_id cannot be empty")

    service = get_enrollment_service()
    audio_bytes_list = []

    for file in audio_files:
        content = await file.read()
        if len(content) == 0:
            raise HTTPException(status_code=400, detail=f"Empty file: {file.filename}")
        audio_bytes_list.append(content)

    result = service.enroll_contact(
        contact_id.strip(),
        audio_bytes_list,
        source_quality=source_quality,
    )

    if not result["success"]:
        raise HTTPException(status_code=500, detail=result.get("error", "Enrollment failed"))

    return result


@router.get("/status/{contact_id}")
async def enrollment_status(contact_id: str):
    """Check if a contact is enrolled."""
    return {
        "contact_id": contact_id,
        "is_enrolled": voiceprint_exists(contact_id),
    }


@router.delete("/{contact_id}")
async def delete_enrollment(contact_id: str):
    """Delete a contact's enrolled voiceprint."""
    deleted = delete_voiceprint(contact_id)
    if not deleted:
        raise HTTPException(status_code=404, detail=f"No voiceprint found for: {contact_id}")
    return {"success": True, "message": f"Voiceprint deleted for {contact_id}"}


@router.get("/list")
async def list_contacts():
    """List all enrolled contacts."""
    return {"enrolled_contacts": list_enrolled_contacts()}
