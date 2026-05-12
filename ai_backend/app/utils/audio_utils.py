import numpy as np
import librosa
import soundfile as sf
import io
import os


SAMPLE_RATE = int(os.getenv("SAMPLE_RATE", 16000))
SEGMENT_DURATION = int(os.getenv("SEGMENT_DURATION", 3))


def load_audio_from_bytes(audio_bytes: bytes, target_sr: int = SAMPLE_RATE) -> np.ndarray:
    """Load audio from raw bytes and resample to target sample rate."""
    buffer = io.BytesIO(audio_bytes)
    audio, sr = librosa.load(buffer, sr=target_sr, mono=True)
    return audio


def load_audio_from_file(file_path: str, target_sr: int = SAMPLE_RATE) -> np.ndarray:
    """Load audio from file path."""
    audio, _ = librosa.load(file_path, sr=target_sr, mono=True)
    return audio


def normalize_audio(audio: np.ndarray) -> np.ndarray:
    """Normalize audio to [-1, 1] range."""
    max_val = np.max(np.abs(audio))
    if max_val > 0:
        return audio / max_val
    return audio


def is_speech(audio: np.ndarray, rms_threshold: float = 0.005) -> bool:
    """
    Check if audio contains actual speech using RMS energy.
    Rejects silence, background noise only, or empty recordings.
    threshold 0.005 = very quiet speech still passes,
    pure silence or near-silence is rejected.
    """
    if len(audio) == 0:
        return False
    rms = float(np.sqrt(np.mean(audio ** 2)))
    return rms > rms_threshold


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
    mel_spec = librosa.feature.melspectrogram(
        y=audio,
        sr=sample_rate,
        n_mels=n_mels,
        n_fft=n_fft,
        hop_length=hop_length,
    )
    log_mel = librosa.power_to_db(mel_spec, ref=np.max)
    return log_mel


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
