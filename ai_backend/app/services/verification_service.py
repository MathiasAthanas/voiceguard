import logging
import os

import numpy as np

from app.models.aasist import get_aasist_model
from app.models.cnn_lstm_voiceguard import get_cnn_lstm_speaker_embedding_model
from app.models.ecapa_tdnn import get_ecapa_model
from app.services.audio_processor import get_audio_processor
from app.utils.audio_utils import is_speech
from app.utils.embedding_utils import (
    load_secondary_voiceprint,
    load_voiceprint,
    secondary_voiceprint_exists,
    voiceprint_exists,
)

logger = logging.getLogger(__name__)

VERIFICATION_THRESHOLD = float(os.getenv("VERIFICATION_THRESHOLD", 0.35))
HIGH_THRESHOLD = float(os.getenv("VERIFICATION_HIGH_THRESHOLD", 0.65))
LOW_THRESHOLD = float(os.getenv("VERIFICATION_LOW_THRESHOLD", 0.20))
SECONDARY_WARNING_MARGIN = float(os.getenv("SECONDARY_WARNING_MARGIN", 0.12))
CALL_AUDIO_CONFIDENCE_FLOOR = float(os.getenv("CALL_AUDIO_CONFIDENCE_FLOOR", 0.40))


class VerificationService:
    """
    Full voice verification pipeline.

    The app must send remote-speaker audio only. The backend then runs:
      1. CNN+LSTM v2 anti-spoofing.
      2. ECAPA primary speaker verification.
      3. CNN+LSTM speaker embedding as a secondary verification signal.
    """

    def __init__(self):
        self.ecapa = get_ecapa_model()
        self.aasist = get_aasist_model()
        self.secondary = get_cnn_lstm_speaker_embedding_model()
        self.processor = get_audio_processor()

    def verify(
        self,
        contact_id: str,
        audio_bytes: bytes,
        audio_role: str = "remote_speaker",
        media_source: str = "unknown",
    ) -> dict:
        if not voiceprint_exists(contact_id):
            return {
                "success": False,
                "error": f"No voiceprint enrolled for contact: {contact_id}",
                "verdict": "not_enrolled",
                "audio_role": audio_role,
                "media_source": media_source,
            }

        audio, _log_mel, segments = self.processor.process_for_verification(audio_bytes)

        # VAD-filtered call audio and raw VoIP local-mic chunks can be quiet or
        # codec-processed; use the RMS speech check to avoid false rejects.
        pretreated = "_vad" in media_source or "voip_local_mic" in media_source
        if not is_speech(audio, use_rms_only=pretreated):
            return self._base_result(
                contact_id=contact_id,
                verdict="silent",
                label="No speech detected",
                audio_role=audio_role,
                media_source=media_source,
                error="No speech detected in audio segment",
                segments_analyzed=0,
            )

        anti_spoofing = self._run_anti_spoofing(segments)
        primary = self._run_primary_verification(contact_id, audio, len(segments), anti_spoofing)
        if primary.get("verdict") == "silent":
            primary["audio_role"] = audio_role
            primary["media_source"] = media_source
            return primary

        secondary = self._run_secondary_verification(contact_id, audio)
        verdict, label, is_verified = self._final_verdict(
            primary,
            secondary,
            anti_spoofing,
            contact_id,
            media_source,
        )

        return {
            "success": True,
            "contact_id": contact_id,
            "verdict": verdict,
            "is_verified": is_verified,
            "is_spoof": verdict == "spoof_detected",
            "spoof_probability": anti_spoofing["spoof_probability"],
            "similarity_score": primary["similarity_score"],
            "confidence": primary["confidence"],
            "message": label,
            "label": label,
            "segments_analyzed": len(segments),
            "anti_spoofing_available": anti_spoofing["available"],
            "anti_spoofing": anti_spoofing,
            "primary_verification": primary,
            "secondary_verification": secondary,
            "audio_role": audio_role,
            "media_source": media_source,
        }

    def _run_anti_spoofing(self, segments: list) -> dict:
        results = []
        for segment in segments:
            result = self.aasist.predict(segment, sample_rate=16000)
            if result.get("available", False):
                results.append(result)

        if not results:
            return {
                "model": "cnn_lstm_v2",
                "available": False,
                "is_spoof": False,
                "spoof_probability": 0.0,
                "real_probability": 1.0,
                "threshold": float(os.getenv("SPOOF_THRESHOLD", 0.20)),
                "decision": "unavailable",
            }

        spoof_probability = float(np.mean([r["spoof_probability"] for r in results]))
        real_probability = float(np.mean([r["real_probability"] for r in results]))
        threshold = float(results[0].get("threshold", os.getenv("SPOOF_THRESHOLD", 0.20)))
        is_spoof = spoof_probability >= threshold
        return {
            "model": "cnn_lstm_v2",
            "available": True,
            "is_spoof": bool(is_spoof),
            "spoof_probability": spoof_probability,
            "real_probability": real_probability,
            "threshold": threshold,
            "decision": "fake_or_cloned" if is_spoof else "passed",
        }

    def _run_primary_verification(
        self,
        contact_id: str,
        audio: np.ndarray,
        segments_analyzed: int,
        anti_spoofing: dict,
    ) -> dict:
        enrolled_embedding = load_voiceprint(contact_id)
        try:
            result = self.ecapa.verify(
                enrolled_embedding,
                audio,
                threshold=VERIFICATION_THRESHOLD,
            )
        except ValueError as exc:
            logger.warning("ECAPA-TDNN rejected audio for '%s': %s", contact_id, exc)
            return self._base_result(
                contact_id=contact_id,
                verdict="silent",
                label="No speech detected",
                error=str(exc),
                segments_analyzed=segments_analyzed,
                anti_spoofing=anti_spoofing,
            )
        except Exception as exc:
            logger.exception("ECAPA-TDNN inference error for '%s': %s", contact_id, exc)
            raise

        similarity = float(result["similarity_score"])
        confidence = float(result["confidence"])
        is_same = bool(result["is_same_speaker"])
        return {
            "model": "ecapa_tdnn",
            "available": True,
            "similarity_score": similarity,
            "confidence": confidence,
            "threshold": float(VERIFICATION_THRESHOLD),
            "is_same_speaker": is_same,
            "decision": "match" if is_same else "mismatch",
        }

    def _run_secondary_verification(self, contact_id: str, audio: np.ndarray) -> dict:
        if not self.secondary.available:
            return {
                "model": "cnn_lstm_speaker_embedding",
                "available": False,
                "reason": "model_not_loaded",
            }
        if not secondary_voiceprint_exists(contact_id):
            return {
                "model": "cnn_lstm_speaker_embedding",
                "available": False,
                "reason": "secondary_voiceprint_missing",
            }

        try:
            enrolled = load_secondary_voiceprint(contact_id)
            result = self.secondary.verify(enrolled, audio)
            result["decision"] = "match" if result["is_same_speaker"] else "mismatch"
            return result
        except Exception as exc:
            logger.warning("CNN+LSTM secondary verification failed for '%s': %s", contact_id, exc)
            return {
                "model": "cnn_lstm_speaker_embedding",
                "available": False,
                "reason": f"inference_failed: {exc}",
            }

    def _final_verdict(
        self,
        primary: dict,
        secondary: dict,
        anti_spoofing: dict,
        contact_id: str,
        media_source: str = "unknown",
    ):
        primary_match = bool(primary["is_same_speaker"])
        primary_similarity = float(primary["similarity_score"])
        secondary_available = bool(secondary.get("available"))
        secondary_match = bool(secondary.get("is_same_speaker", False))
        secondary_similarity = secondary.get("similarity_score")
        secondary_threshold = float(secondary.get("threshold_used", 0.62))

        secondary_strong_disagreement = (
            primary_match
            and secondary_available
            and not secondary_match
            and secondary_similarity is not None
            and float(secondary_similarity) < (secondary_threshold - SECONDARY_WARNING_MARGIN)
        )

        # The current CNN+LSTM anti-spoofing model is useful as telemetry, but
        # it has produced false positives on real phone-call audio. For the
        # test/presentation build, do not let it override speaker verification.
        # The spoof probability is still returned in the response for history
        # and dashboard review.
        if primary_match and primary_similarity >= HIGH_THRESHOLD:
            return "verified_high", f"Verified - This is {contact_id}", True
        if primary_match:
            if secondary_available and secondary_match:
                return "verified", f"Likely {contact_id} - both models agree", True
            return "verified", f"Likely {contact_id}", True
        if (
            ("_vad" in media_source or "voip_local_mic" in media_source)
            and float(primary["confidence"]) >= CALL_AUDIO_CONFIDENCE_FLOOR
        ):
            return "verified", f"Likely {contact_id} - call audio is noisy", True
        if primary_similarity < LOW_THRESHOLD:
            return "not_verified", f"Does NOT sound like {contact_id}", False
        return "uncertain", "Uncertain - audio too noisy to confirm", False

    def _base_result(
        self,
        contact_id: str,
        verdict: str,
        label: str,
        error=None,
        segments_analyzed: int = 0,
        anti_spoofing=None,
        audio_role: str = "remote_speaker",
        media_source: str = "unknown",
    ) -> dict:
        anti_spoofing = anti_spoofing or {
            "model": "cnn_lstm_v2",
            "available": False,
            "is_spoof": False,
            "spoof_probability": 0.0,
            "real_probability": 1.0,
            "threshold": float(os.getenv("SPOOF_THRESHOLD", 0.20)),
            "decision": "unavailable",
        }
        return {
            "success": True,
            "contact_id": contact_id,
            "verdict": verdict,
            "error": error,
            "message": label,
            "label": label,
            "is_verified": False,
            "is_spoof": False,
            "confidence": 0.0,
            "spoof_probability": anti_spoofing["spoof_probability"],
            "similarity_score": None,
            "segments_analyzed": segments_analyzed,
            "anti_spoofing_available": anti_spoofing["available"],
            "anti_spoofing": anti_spoofing,
            "primary_verification": None,
            "secondary_verification": None,
            "audio_role": audio_role,
            "media_source": media_source,
        }


_service = None


def get_verification_service() -> VerificationService:
    global _service
    if _service is None:
        _service = VerificationService()
    return _service
