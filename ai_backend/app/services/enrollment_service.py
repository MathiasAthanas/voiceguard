import numpy as np

from app.models.cnn_lstm_voiceguard import get_cnn_lstm_speaker_embedding_model
from app.models.ecapa_tdnn import get_ecapa_model
from app.services.audio_processor import get_audio_processor
from app.utils.audio_utils import is_speech, load_audio_from_bytes, normalize_audio
from app.utils.embedding_utils import (
    save_voiceprint,
    save_secondary_voiceprint,
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
        self.secondary = get_cnn_lstm_speaker_embedding_model()
        self.processor = get_audio_processor()

    def enroll_contact(
        self,
        contact_id: str,
        audio_bytes_list: list,
        source_quality: str = "high",
    ) -> dict:
        """
        Enroll a contact using one or more audio samples.

        For call-time enrollment (`source_quality=low`), this is deliberately
        strict: it requires several remote-speaker samples and checks embedding
        consistency before writing a voiceprint. A bad first-call voiceprint is
        worse than no voiceprint because every future verification depends on it.
        """
        if not audio_bytes_list:
            return {"success": False, "error": "No audio samples provided"}

        source_quality = (source_quality or "high").lower().strip()
        is_call_time = source_quality == "low"
        # High-quality enrollment requires at least 2 samples so the
        # consistency check is meaningful (1 sample always scores 1.0).
        # Call-time audio requires more samples because quality is lower and
        # the first two segments are discarded by the Flutter side (10 s warmup).
        min_valid_samples = 3 if is_call_time else 2
        min_duration_seconds = 1.0 if is_call_time else 2.0
        # 0.15 accepted virtually any two segments as consistent; 0.40 was too
        # strict and rejected most cellular audio. 0.25 is the calibrated middle.
        consistency_threshold = 0.25 if is_call_time else 0.45

        embeddings = []
        secondary_embeddings = []
        accepted_metrics = []
        rejected_samples = []

        for i, audio_bytes in enumerate(audio_bytes_list):
            try:
                raw_audio = load_audio_from_bytes(audio_bytes, self.processor.sample_rate)
                quality = self._audio_quality(raw_audio)

                if quality["duration_seconds"] < min_duration_seconds:
                    rejected_samples.append({
                        "sample": i + 1,
                        "reason": "too_short",
                        **quality,
                    })
                    continue

                normalized = normalize_audio(raw_audio)
                # Call-time audio is already VAD-filtered on the device;
                # skip Silero and use the RMS check to avoid false rejects
                # on codec-compressed earpiece audio.
                if not is_speech(normalized, use_rms_only=is_call_time):
                    rejected_samples.append({
                        "sample": i + 1,
                        "reason": "no_speech",
                        **quality,
                    })
                    continue

                audio = self.processor.process_for_enrollment(audio_bytes)
                embedding = self.ecapa.get_embedding(audio)
                embeddings.append(embedding)
                if self.secondary.available:
                    try:
                        secondary_embeddings.append(self.secondary.get_embedding(audio))
                    except Exception as secondary_error:
                        print(
                            "Warning: Secondary speaker embedding failed "
                            f"for sample {i + 1}: {secondary_error}"
                        )
                accepted_metrics.append(quality)
                print(f"Processed sample {i + 1}/{len(audio_bytes_list)} for {contact_id}")
            except Exception as e:
                rejected_samples.append({
                    "sample": i + 1,
                    "reason": f"processing_failed: {e}",
                })
                print(f"Warning: Failed to process sample {i + 1}: {e}")
                continue

        if len(embeddings) < min_valid_samples:
            return {
                "success": False,
                "error": (
                    f"Only {len(embeddings)} usable voice sample(s). "
                    f"Need at least {min_valid_samples} clean remote-speaker sample(s)."
                ),
                "samples_processed": len(embeddings),
                "samples_required": min_valid_samples,
                "rejected_samples": rejected_samples,
            }

        consistency = self._embedding_consistency(embeddings)
        if consistency < consistency_threshold:
            return {
                "success": False,
                "error": (
                    "Enrollment samples are not consistent enough for a safe "
                    "voiceprint. Ask the remote speaker to talk clearly while "
                    "the phone owner stays quiet."
                ),
                "samples_processed": len(embeddings),
                "consistency_score": consistency,
                "consistency_required": consistency_threshold,
                "rejected_samples": rejected_samples,
            }

        # Average embeddings for more robust voiceprint
        if len(embeddings) > 1:
            final_embedding = average_embeddings(embeddings)
        else:
            final_embedding = embeddings[0]

        save_voiceprint(contact_id, final_embedding)
        secondary_saved = False
        if secondary_embeddings:
            save_secondary_voiceprint(contact_id, average_embeddings(secondary_embeddings))
            secondary_saved = True

        return {
            "success": True,
            "contact_id": contact_id,
            "samples_processed": len(embeddings),
            "source_quality": source_quality,
            "consistency_score": consistency,
            "quality": accepted_metrics,
            "embedding_dim": len(final_embedding),
            "secondary_embedding_saved": secondary_saved,
            "secondary_embedding_available": self.secondary.available,
            "message": f"Successfully enrolled {contact_id} with {len(embeddings)} sample(s)",
        }

    def _audio_quality(self, audio: np.ndarray) -> dict:
        if len(audio) == 0:
            return {
                "duration_seconds": 0.0,
                "rms": 0.0,
                "peak": 0.0,
            }

        duration = len(audio) / float(self.processor.sample_rate)
        rms = float(np.sqrt(np.mean(audio ** 2)))
        peak = float(np.max(np.abs(audio)))
        return {
            "duration_seconds": round(duration, 3),
            "rms": round(rms, 6),
            "peak": round(peak, 6),
        }

    def _embedding_consistency(self, embeddings: list) -> float:
        if len(embeddings) < 2:
            return 1.0

        scores = []
        for i in range(len(embeddings)):
            for j in range(i + 1, len(embeddings)):
                scores.append(self.ecapa.compute_similarity(embeddings[i], embeddings[j]))

        return float(np.mean(scores)) if scores else 1.0

    def is_enrolled(self, contact_id: str) -> bool:
        return voiceprint_exists(contact_id)


# Singleton
_service = None


def get_enrollment_service() -> EnrollmentService:
    global _service
    if _service is None:
        _service = EnrollmentService()
    return _service
