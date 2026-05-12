import numpy as np
from app.utils.audio_utils import (
    load_audio_from_bytes,
    normalize_audio,
    split_into_segments,
    compute_log_mel_spectrogram,
)


class AudioProcessor:
    """
    Central audio processing service.
    Handles all preprocessing steps before AI model inference.
    """

    def __init__(self, sample_rate: int = 16000, segment_duration: int = 3):
        self.sample_rate = sample_rate
        self.segment_duration = segment_duration

    def process_for_enrollment(self, audio_bytes: bytes) -> np.ndarray:
        """
        Process audio for voice enrollment.
        Returns normalized audio array ready for embedding extraction.
        """
        audio = load_audio_from_bytes(audio_bytes, self.sample_rate)
        audio = normalize_audio(audio)

        # Ensure minimum length (at least 3 seconds)
        min_length = self.sample_rate * self.segment_duration
        if len(audio) < min_length:
            audio = np.pad(audio, (0, min_length - len(audio)))

        return audio

    def process_for_verification(self, audio_bytes: bytes) -> tuple:
        """
        Process audio for real-time verification.
        Returns (audio, log_mel_spectrogram, segments)
        """
        audio = load_audio_from_bytes(audio_bytes, self.sample_rate)
        audio = normalize_audio(audio)
        log_mel = compute_log_mel_spectrogram(audio, self.sample_rate)
        segments = split_into_segments(audio, self.segment_duration, self.sample_rate)

        return audio, log_mel, segments

    def process_segment(self, audio: np.ndarray) -> np.ndarray:
        """Process a single audio segment for anti-spoofing."""
        return compute_log_mel_spectrogram(audio, self.sample_rate)


# Singleton
_processor = None


def get_audio_processor() -> AudioProcessor:
    global _processor
    if _processor is None:
        _processor = AudioProcessor()
    return _processor
