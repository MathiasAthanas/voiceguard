import logging
import math
import numpy as np
import soundfile as sf
import io
import os
from scipy import signal


logger = logging.getLogger(__name__)

SAMPLE_RATE = int(os.getenv("SAMPLE_RATE", 16000))
SEGMENT_DURATION = int(os.getenv("SEGMENT_DURATION", 3))

# ---------------------------------------------------------------------------
# Silero VAD — loaded once on first call, falls back to RMS if unavailable.
# ---------------------------------------------------------------------------
_silero_model = None  # None = not yet attempted; False = failed/unavailable


def _get_silero_model():
    """Lazy-load the Silero VAD model (singleton). Returns None on failure."""
    global _silero_model
    if _silero_model is not None:
        return _silero_model if _silero_model is not False else None
    try:
        from silero_vad import load_silero_vad  # noqa: PLC0415
        _silero_model = load_silero_vad()
        logger.info("Silero VAD loaded successfully")
    except Exception as exc:
        logger.warning("Silero VAD unavailable — falling back to RMS energy: %s", exc)
        _silero_model = False
    return _silero_model if _silero_model is not False else None


def load_audio_from_bytes(audio_bytes: bytes, target_sr: int = SAMPLE_RATE) -> np.ndarray:
    """Load audio from raw bytes and resample to target sample rate."""
    buffer = io.BytesIO(audio_bytes)
    audio, sample_rate = sf.read(buffer, dtype="float32", always_2d=False)
    return _prepare_audio(audio, sample_rate, target_sr)


def load_audio_from_file(file_path: str, target_sr: int = SAMPLE_RATE) -> np.ndarray:
    """Load audio from file path."""
    audio, sample_rate = sf.read(file_path, dtype="float32", always_2d=False)
    return _prepare_audio(audio, sample_rate, target_sr)


def _prepare_audio(audio: np.ndarray, sample_rate: int, target_sr: int) -> np.ndarray:
    """Convert decoded audio to mono float32 at the requested sample rate."""
    audio = np.asarray(audio, dtype=np.float32)
    if audio.ndim > 1:
        audio = np.mean(audio, axis=1)
    if sample_rate != target_sr:
        divisor = math.gcd(int(sample_rate), int(target_sr))
        audio = signal.resample_poly(
            audio,
            int(target_sr) // divisor,
            int(sample_rate) // divisor,
        ).astype(np.float32)
    return audio.astype(np.float32, copy=False)


def normalize_audio(audio: np.ndarray) -> np.ndarray:
    """Normalize audio to [-1, 1] range."""
    if audio.size == 0:
        return audio.astype(np.float32, copy=False)
    max_val = np.max(np.abs(audio))
    if max_val > 0:
        return audio / max_val
    return audio


def is_speech(audio: np.ndarray, rms_threshold: float = 0.005) -> bool:
    """
    Detect whether the audio contains actual speech.

    Primary method: Silero VAD (ML-based, robust to background noise, hold
    music, and HVAC hum that would fool a plain RMS check).
    Fallback: RMS energy threshold (used only when Silero is unavailable).
    """
    if len(audio) == 0:
        return False

    model = _get_silero_model()
    if model is not None:
        try:
            import torch  # noqa: PLC0415
            from silero_vad import get_speech_timestamps  # noqa: PLC0415

            tensor = torch.FloatTensor(audio)
            # Silero requires at least 512 samples; pad if shorter.
            if tensor.shape[0] < 512:
                tensor = torch.nn.functional.pad(tensor, (0, 512 - tensor.shape[0]))
            timestamps = get_speech_timestamps(tensor, model, sampling_rate=SAMPLE_RATE)
            return len(timestamps) > 0
        except Exception as exc:
            logger.warning("Silero VAD inference error, using RMS fallback: %s", exc)

    # RMS fallback — simple energy gate
    return float(np.sqrt(np.mean(audio ** 2))) > rms_threshold


def split_into_segments(
    audio: np.ndarray,
    segment_duration: int = SEGMENT_DURATION,
    sample_rate: int = SAMPLE_RATE,
) -> list:
    """
    Split audio into fixed-length segments.
    Pads the last segment if it is shorter than segment_duration.
    """
    segment_length = segment_duration * sample_rate
    segments = []

    for start in range(0, len(audio), segment_length):
        segment = audio[start : start + segment_length]

        # Pad if too short
        if len(segment) < segment_length:
            segment = np.pad(segment, (0, segment_length - len(segment)))

        segments.append(segment)

    return segments


def compute_log_mel_spectrogram(
    audio: np.ndarray,
    sample_rate: int = SAMPLE_RATE,
    n_mels: int = 64,
    n_fft: int = 512,
    hop_length: int = 160,
) -> np.ndarray:
    """
    Compute log-mel spectrogram from audio array.
    Standard feature for anti-spoofing models.
    """
    # Keep runtime extraction aligned with the trained VoiceGuard models.
    from app.models.cnn_lstm_voiceguard import audio_to_logmel

    if sample_rate != SAMPLE_RATE:
        audio = _prepare_audio(audio, sample_rate, SAMPLE_RATE)
    return audio_to_logmel(audio)


def preprocess_audio(audio_bytes: bytes) -> tuple:
    """
    Full preprocessing pipeline.
    Returns (normalized_audio, log_mel_spectrogram, segments)
    """
    audio = load_audio_from_bytes(audio_bytes)
    audio = normalize_audio(audio)
    log_mel = compute_log_mel_spectrogram(audio)
    segments = split_into_segments(audio)

    return audio, log_mel, segments


def save_audio(audio: np.ndarray, file_path: str, sample_rate: int = SAMPLE_RATE):
    """Save audio array to file."""
    sf.write(file_path, audio, sample_rate)
