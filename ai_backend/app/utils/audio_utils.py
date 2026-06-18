import logging
import math
import tempfile
import numpy as np
import soundfile as sf
import io
import os
from scipy import signal

# Container formats that soundfile cannot read — routed through torchaudio+ffmpeg.
_CONTAINER_EXTS = frozenset({'.mp4', '.m4a', '.aac', '.mp3', '.webm'})


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
    """Load audio from raw bytes. WAV/FLAC/OGG via soundfile; MP4/AAC via torchaudio."""
    # Fast path: soundfile reads WAV/FLAC/OGG directly from memory.
    try:
        audio, sample_rate = sf.read(io.BytesIO(audio_bytes), dtype="float32", always_2d=False)
        return _prepare_audio(audio, sample_rate, target_sr)
    except Exception:
        pass

    # Container format (MP4/AAC from flutter_webrtc OUTPUT recorder, etc.).
    # torchaudio needs a real file path — write to a temp file then decode.
    suffix = _sniff_container_ext(audio_bytes)
    fd, tmp_path = tempfile.mkstemp(suffix=suffix)
    try:
        os.write(fd, audio_bytes)
        os.close(fd)
        return _load_via_torchaudio(tmp_path, target_sr)
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def load_audio_from_file(file_path: str, target_sr: int = SAMPLE_RATE) -> np.ndarray:
    """Load audio from file. WAV/FLAC/OGG via soundfile; MP4/AAC/M4A via torchaudio."""
    ext = os.path.splitext(file_path.lower())[1]
    if ext in _CONTAINER_EXTS:
        return _load_via_torchaudio(file_path, target_sr)
    audio, sample_rate = sf.read(file_path, dtype="float32", always_2d=False)
    return _prepare_audio(audio, sample_rate, target_sr)


def _load_via_torchaudio(file_path: str, target_sr: int) -> np.ndarray:
    """Decode container audio (MP4/AAC/M4A). Uses PyAV first (ships bundled FFmpeg DLLs,
    works on Windows without a separate ffmpeg install); falls back to torchaudio."""
    try:
        return _load_via_av(file_path, target_sr)
    except Exception as av_exc:
        logger.warning("PyAV decode failed (%s), trying torchaudio", av_exc)

    import torchaudio  # noqa: PLC0415
    # Force the ffmpeg dispatcher so torchaudio doesn't route to soundfile
    try:
        waveform, sample_rate = torchaudio.load(file_path, format="mp4a-latm")
    except Exception:
        waveform, sample_rate = torchaudio.load(file_path)
    audio = waveform.mean(dim=0).numpy().astype(np.float32)
    return _prepare_audio(audio, sample_rate, target_sr)


def _load_via_av(file_path: str, target_sr: int) -> np.ndarray:
    """Decode any audio container via PyAV (bundled FFmpeg). Works on Windows Python 3.8+."""
    import av  # noqa: PLC0415
    with av.open(file_path) as container:
        stream = next((s for s in container.streams if s.type == "audio"), None)
        if stream is None:
            raise ValueError("No audio stream found")
        src_sr = stream.sample_rate
        frames = []
        for packet in container.demux(stream):
            for frame in packet.decode():
                # to_ndarray with 'fltp' gives float32, shape (channels, samples)
                arr = frame.to_ndarray(format="fltp")
                frames.append(arr.mean(axis=0))  # mono
    if not frames:
        raise ValueError("No audio frames decoded")
    audio = np.concatenate(frames).astype(np.float32)
    return _prepare_audio(audio, src_sr, target_sr)


def _sniff_container_ext(data: bytes) -> str:
    """Guess the container type from magic bytes to select a temp-file extension."""
    # MP4/M4A: 4-byte box size then 'ftyp' at offset 4
    if len(data) >= 8 and data[4:8] == b'ftyp':
        return '.mp4'
    # Raw AAC ADTS: sync word 0xFFF1 (MPEG-4) or 0xFFF9 (MPEG-2)
    if len(data) >= 2 and data[:2] in (b'\xff\xf1', b'\xff\xf9'):
        return '.aac'
    return '.mp4'  # flutter_webrtc AudioFileRenderer always wraps in MP4


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


def is_speech(
    audio: np.ndarray,
    rms_threshold: float = 0.005,
    use_rms_only: bool = False,
) -> bool:
    """
    Detect whether the audio contains actual speech.

    Primary method: Silero VAD (ML-based, robust to background noise, hold
    music, and HVAC hum that would fool a plain RMS check).
    Fallback: RMS energy threshold (used when Silero is unavailable).

    Pass use_rms_only=True for audio that has already been VAD-filtered on
    the device (call-time segments). Running Silero on codec-compressed
    earpiece audio produces false negatives because the signal no longer
    resembles clean microphone speech.
    """
    if len(audio) == 0:
        return False

    if not use_rms_only:
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

    # RMS fallback — simple energy gate (also used directly for pre-filtered audio)
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
