import numpy as np
from app.models.ecapa_tdnn import get_ecapa_model
from app.services.audio_processor import get_audio_processor
from app.utils.audio_utils import is_speech
from app.utils.embedding_utils import (
    save_voiceprint,
    voiceprint_exists,
    average_embeddings,
)


class EnrollmentService:
    """
    Handles enrolling a contact's voice.
    Accepts one or multiple audio samples and saves a voiceprint.
    """

    def __init__(self):
        self.ecapa = get_ecapa_model()
        self.processor = get_audio_processor()

    def enroll_contact(self, contact_id: str, audio_bytes_list: list) -> dict:
        """
        Enroll a contact using one or more audio samples.

        Args:
            contact_id: Unique identifier for the contact
            audio_bytes_list: List of raw audio byte arrays

        Returns:
            dict with enrollment status and details
        """
        if not audio_bytes_list:
            return {"success": False, "error": "No audio samples provided"}

        embeddings = []

        for i, audio_bytes in enumerate(audio_bytes_list):
            try:
                audio = self.processor.process_for_enrollment(audio_bytes)

                # Reject silent samples
                if not is_speech(audio):
                    print(f"Warning: Sample {i + 1} appears silent — skipping")
                    continue

                embedding = self.ecapa.get_embedding(audio)
                embeddings.append(embedding)
                print(f"Processed sample {i + 1}/{len(audio_bytes_list)} for {contact_id}")
            except Exception as e:
                print(f"Warning: Failed to process sample {i + 1}: {e}")
                continue

        if not embeddings:
            return {"success": False, "error": "All audio samples failed processing"}

        # Average embeddings for more robust voiceprint
        if len(embeddings) > 1:
            final_embedding = average_embeddings(embeddings)
        else:
            final_embedding = embeddings[0]

        save_voiceprint(contact_id, final_embedding)

        return {
            "success": True,
            "contact_id": contact_id,
            "samples_processed": len(embeddings),
            "embedding_dim": len(final_embedding),
            "message": f"Successfully enrolled {contact_id} with {len(embeddings)} sample(s)",
        }

    def is_enrolled(self, contact_id: str) -> bool:
        return voiceprint_exists(contact_id)


# Singleton
_service = None


def get_enrollment_service() -> EnrollmentService:
    global _service
    if _service is None:
        _service = EnrollmentService()
    return _service
