import logging
import os

import numpy as np

from app.models.aasist import get_aasist_model
from app.models.cnn_lstm_voiceguard import get_cnn_lstm_speaker_embedding_model
from app.models.ecapa_tdnn import get_ecapa_model
from app.services.audio_processor import get_audio_processor
from app.utils.audio_utils import is_speech
from app.utils.debug_audio import save_debug_audio
from app.utils.enhance import maybe_enhance
from app.utils.embedding_utils import (
    as_embedding_matrix,
    load_secondary_voiceprint,
    load_voiceprint,
    secondary_voiceprint_exists,
    voiceprint_exists,
)

logger = logging.getLogger(__name__)

# Cosine-similarity thresholds are MODEL-SPECIFIC — each speaker model puts
# same-speaker scores on a different scale, so one threshold can't serve all.
# Measured ceilings on narrowband cellular audio:
#   WavLM-Base+ : same-speaker ~0.75–0.90  → 0.68 verify
#   WeSpeaker   : same-speaker ~0.45–0.65  → 0.40 verify (0.68 rejected everyone)
#   TitaNet     : similar lower scale to WeSpeaker
# (verify, high, low) per backend. Override any value with a per-model env var,
# e.g. WESPEAKER_VERIFICATION_THRESHOLD / WESPEAKER_HIGH_THRESHOLD / _LOW_.
_THRESHOLD_DEFAULTS = {
    "wavlm":     (0.68, 0.85, 0.55),
    "wespeaker": (0.40, 0.55, 0.25),
    "titanet":   (0.45, 0.60, 0.30),
}


def display_confidence(similarity, low, verify, high):
    """Presentational-only remap of the raw cosine to a 0..1 confidence anchored
    on the decision thresholds, so the shown % means "how far above/below the
    decision line" and is consistent across models (WeSpeaker's 0.52 reads ~0.85
    like WavLM's 0.80). Anchors: low→0.30, verify→0.65, high→0.90, then linear
    extrapolation, clamped to [0.02, 0.99]. Does NOT affect the verdict.
    """
    if similarity is None:
        return None
    s = float(similarity)
    if s <= verify:
        slope = (0.65 - 0.30) / max(verify - low, 1e-6)
    else:
        slope = (0.90 - 0.65) / max(high - verify, 1e-6)
    val = 0.65 + (s - verify) * slope
    return float(min(0.99, max(0.02, val)))


def _resolve_thresholds():
    backend = os.getenv("SPEAKER_MODEL", "wavlm").strip().lower()
    dv, dh, dl = _THRESHOLD_DEFAULTS.get(backend, _THRESHOLD_DEFAULTS["wavlm"])
    pfx = backend.upper()
    if backend == "wavlm":
        # Back-compat: the generic VERIFICATION_THRESHOLD applies to WavLM.
        v = float(os.getenv("VERIFICATION_THRESHOLD", dv))
        h = float(os.getenv("VERIFICATION_HIGH_THRESHOLD", dh))
        low = float(os.getenv("VERIFICATION_LOW_THRESHOLD", dl))
    else:
        v = float(os.getenv(f"{pfx}_VERIFICATION_THRESHOLD", dv))
        h = float(os.getenv(f"{pfx}_HIGH_THRESHOLD", dh))
        low = float(os.getenv(f"{pfx}_LOW_THRESHOLD", dl))
    return v, h, low


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
        # Thresholds chosen for the active speaker model (see _resolve_thresholds).
        self.threshold, self.high_threshold, self.low_threshold = _resolve_thresholds()
        logger.info(
            "Verification thresholds for model '%s': verify=%.2f high=%.2f low=%.2f",
            os.getenv("SPEAKER_MODEL", "wavlm"),
            self.threshold, self.high_threshold, self.low_threshold,
        )

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
        if primary.get("verdict") in {"silent", "not_enrolled"}:
            primary["audio_role"] = audio_role
            primary["media_source"] = media_source
            return primary
        if "is_same_speaker" not in primary:
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

        # Debug: save the exact audio the model scored, with the similarity and
        # verdict in the filename, so a "male impostor that passed" can be found
        # and played back (off unless DEBUG_SAVE_AUDIO=true).
        save_debug_audio(
            contact_id, "verify", audio,
            score=primary.get("similarity_score"),
            verdict=verdict,
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
            # Presentational confidence anchored on the model's thresholds — what
            # the UI shows (raw cosine is misleading as a %). Verdict is unaffected.
            "display_confidence": display_confidence(
                primary["similarity_score"],
                self.low_threshold, self.threshold, self.high_threshold,
            ),
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
        enrolled = as_embedding_matrix(load_voiceprint(contact_id))

        # A voiceprint whose embedding dim doesn't match the active model was
        # enrolled under a different backend (legacy ECAPA 192-dim, or WavLM
        # 512-dim while TitaNet 192-dim is now active, etc). Cross-space
        # similarity is meaningless — force a re-enroll.
        expected_dim = getattr(self.ecapa, "embedding_dim", enrolled.shape[1])
        if enrolled.shape[1] != expected_dim:
            logger.warning(
                "Voiceprint dim %d for '%s' != model dim %d — re-enrollment required",
                enrolled.shape[1], contact_id, expected_dim,
            )
            return self._base_result(
                contact_id=contact_id,
                verdict="not_enrolled",
                label="Re-enrollment required — model was changed",
                error="Contact was enrolled with a different model. Please re-enroll.",
                segments_analyzed=segments_analyzed,
                anti_spoofing=anti_spoofing,
            )

        # Fix 3: enhance codec-degraded VOICE_DOWNLINK audio before embedding
        # (no-op unless ENABLE_SPEECH_ENHANCEMENT=true and DeepFilterNet is
        # installed). Fix 2: score-average across all stored templates.
        audio = maybe_enhance(audio, 16000)
        try:
            result = self.ecapa.verify_set(
                enrolled,
                audio,
                threshold=self.threshold,
            )
        except ValueError as exc:
            logger.warning("WavLM rejected audio for '%s': %s", contact_id, exc)
            return self._base_result(
                contact_id=contact_id,
                verdict="silent",
                label="No speech detected",
                error=str(exc),
                segments_analyzed=segments_analyzed,
                anti_spoofing=anti_spoofing,
            )
        except Exception as exc:
            logger.exception("WavLM inference error for '%s': %s", contact_id, exc)
            raise

        similarity = float(result["similarity_score"])
        confidence = float(result["confidence"])
        is_same = bool(result["is_same_speaker"])
        backend = os.getenv("SPEAKER_MODEL", "wavlm").strip().lower()
        _model_names = {
            "titanet": "titanet_large",
            "wespeaker": "wespeaker",
            "wavlm": "wavlm_base_plus",
        }
        return {
            "model": _model_names.get(backend, "wavlm_base_plus"),
            "available": True,
            "similarity_score": similarity,
            "confidence": confidence,
            "threshold": float(self.threshold),
            "is_same_speaker": is_same,
            "decision": "match" if is_same else "mismatch",
            "threshold_used": float(self.threshold),
            # Score-averaging telemetry (Fix 2): mean is the decision score.
            "per_template_scores": result.get("per_template_scores"),
            "max_template_score": result.get("max_template_score"),
            "num_templates": result.get("num_templates"),
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
        media_source: str = "unknown",  # kept for API compatibility
    ):
        primary_match = bool(primary["is_same_speaker"])
        primary_similarity = float(primary["similarity_score"])

        # Secondary CNN+LSTM speaker embedding is kept for telemetry but excluded
        # from the verdict: it scored 92% for the true speaker and 90% for an
        # impostor in real-world testing — no discriminative value.
        # The media_source bypass is also removed: it was a client-controlled
        # string that could return "verified" even when ECAPA said mismatch.

        if primary_match and primary_similarity >= self.high_threshold:
            return "verified_high", f"Verified — this is {contact_id}", True
        if primary_match:
            return "verified", f"Likely {contact_id}", True
        if primary_similarity < self.low_threshold:
            return "not_verified", f"Does NOT sound like {contact_id}", False
        return "uncertain", "Uncertain — audio quality too low to confirm", False

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
