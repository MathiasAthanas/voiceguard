import logging
import os

import numpy as np

from app.models.aasist import get_aasist_model
from app.models.ecapa_tdnn import get_ecapa_model
from app.services.audio_processor import get_audio_processor
from app.utils.audio_utils import is_speech
from app.utils.embedding_utils import load_voiceprint, voiceprint_exists

logger = logging.getLogger(__name__)

VERIFICATION_THRESHOLD = float(os.getenv("VERIFICATION_THRESHOLD", 0.75))


class VerificationService:
    """
    Full voice verification pipeline.
    Runs anti-spoofing first when AASIST weights are available, then speaker ID.
    """

    def __init__(self):
        self.ecapa = get_ecapa_model()
        self.aasist = get_aasist_model()
        self.processor = get_audio_processor()

    def verify(self, contact_id: str, audio_bytes: bytes) -> dict:
        if not voiceprint_exists(contact_id):
            return {
                "success": False,
                "error": f"No voiceprint enrolled for contact: {contact_id}",
                "verdict": "not_enrolled",
            }

        audio, _log_mel, segments = self.processor.process_for_verification(audio_bytes)

        # Reject silent audio immediately — no speech means no meaningful result
        if not is_speech(audio):
            return {
                "success": True,
                "verdict": "silent",
                "error": "No speech detected in audio segment",
                "message": "No speech detected",
                "label": "No speech detected",
                "is_verified": False,
                "is_spoof": False,
                "confidence": 0.0,
                "spoof_probability": 0.0,
                "similarity_score": None,
                "segments_analyzed": 0,
                "anti_spoofing_available": False,
            }

        spoof_results = []
        for segment in segments:
            # Pass raw audio waveform — SpeechBrain computes its own features.
            result = self.aasist.predict(segment, sample_rate=16000)
            if result.get("available", False):  # only include when model is active
                spoof_results.append(result)

        anti_spoofing_available = bool(spoof_results)
        avg_spoof_prob = (
            np.mean([r["spoof_probability"] for r in spoof_results])
            if anti_spoofing_available
            else 0.0
        )
        is_spoof = (
            anti_spoofing_available
            and avg_spoof_prob > float(os.getenv("SPOOF_THRESHOLD", 0.5))
        )

        if is_spoof:
            return {
                "success": True,
                "contact_id": contact_id,
                "verdict": "spoof_detected",
                "is_verified": False,
                "is_spoof": True,
                "spoof_probability": float(avg_spoof_prob),
                "similarity_score": None,
                "confidence": float(avg_spoof_prob),
                "message": "AI-generated or cloned voice detected",
                "label": "AI voice detected",
                "segments_analyzed": len(segments),
                "anti_spoofing_available": anti_spoofing_available,
            }

        enrolled_embedding = load_voiceprint(contact_id)
        try:
            speaker_result = self.ecapa.verify(
                enrolled_embedding,
                audio,
                threshold=VERIFICATION_THRESHOLD,
            )
        except ValueError as exc:
            # ECAPA rejected audio (e.g. RMS too low even though is_speech passed)
            logger.warning("ECAPA-TDNN rejected audio for '%s': %s", contact_id, exc)
            return {
                "success": True,
                "verdict": "silent",
                "error": str(exc),
                "message": "No speech detected",
                "label": "No speech detected",
                "is_verified": False,
                "is_spoof": False,
                "confidence": 0.0,
                "spoof_probability": 0.0,
                "similarity_score": None,
                "segments_analyzed": len(segments),
                "anti_spoofing_available": anti_spoofing_available,
            }
        except Exception as exc:
            logger.exception("ECAPA-TDNN inference error for '%s': %s", contact_id, exc)
            raise

        is_verified = speaker_result["is_same_speaker"]
        similarity  = speaker_result["similarity_score"]
        confidence  = speaker_result["confidence"]   # (similarity + 1) / 2

        # Tier thresholds calibrated for compressed phone/VoIP microphone audio.
        # Same speaker on a phone call typically scores 0.45-0.70 (not 0.85+).
        # Different speaker in the same room typically scores 0.25-0.45.
        #
        #   verified_high : similarity >= 0.65  → very strong match for phone audio
        #   verified      : similarity >= threshold (0.55 default)
        #   not_verified  : similarity < 0.28   → clearly a different person
        #   uncertain     : everything else (noisy audio, borderline match)
        HIGH_THRESHOLD = 0.65
        LOW_THRESHOLD  = 0.28

        if is_verified and similarity >= HIGH_THRESHOLD:
            verdict = "verified_high"
            label   = f"✅ Verified — This is {contact_id}"
        elif is_verified:
            verdict = "verified"
            label   = f"✅ Likely {contact_id}"
        elif similarity < LOW_THRESHOLD:
            verdict = "not_verified"
            label   = f"❌ Does NOT sound like {contact_id}"
        else:
            verdict = "uncertain"
            label   = "⚠️ Uncertain — audio too noisy to confirm"

        return {
            "success": True,
            "contact_id": contact_id,
            "verdict": verdict,
            "is_verified": is_verified,
            "is_spoof": False,
            "spoof_probability": float(avg_spoof_prob),
            "similarity_score": float(similarity),
            "confidence": float(confidence),
            "message": label,
            "label": label,
            "segments_analyzed": len(segments),
            "anti_spoofing_available": anti_spoofing_available,
        }


_service = None


def get_verification_service() -> VerificationService:
    global _service
    if _service is None:
        _service = VerificationService()
    return _service
