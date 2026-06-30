"""Debug helper: save the exact audio the speaker model embeds, so it can be
listened to and inspected.

Both enrollment samples and verification samples are written as 16 kHz mono WAV
files under DEBUG_AUDIO_DIR/<contact>/, with the similarity score and verdict in
the verification filenames so a "male impostor that passed" can be found and
played back immediately.

Env-gated by DEBUG_SAVE_AUDIO (default off) — turn on only while debugging, then
off again so it doesn't fill the disk.
"""

import datetime
import os

import numpy as np
import soundfile as sf

DEBUG_AUDIO_DIR = os.getenv("DEBUG_AUDIO_DIR", "debug_audio")


def debug_audio_enabled() -> bool:
    return os.getenv("DEBUG_SAVE_AUDIO", "false").strip().lower() in (
        "1", "true", "yes", "on",
    )


def _safe(name: str) -> str:
    cleaned = "".join(c for c in name if c.isalnum() or c in ("_", "-", " ")).strip()
    return cleaned or "unknown"


def save_debug_audio(
    contact_id: str,
    kind: str,
    audio: np.ndarray,
    sample_rate: int = 16000,
    score: float = None,
    verdict: str = None,
) -> str:
    """Write [audio] to DEBUG_AUDIO_DIR/<contact>/<kind>_<time>[_sim..][_verdict].wav.

    Returns the path written, or None if disabled / on error (never raises — a
    debug save must not break enrollment or verification).
    """
    if not debug_audio_enabled():
        return None
    try:
        folder = os.path.join(DEBUG_AUDIO_DIR, _safe(contact_id))
        os.makedirs(folder, exist_ok=True)

        ts = datetime.datetime.now().strftime("%H%M%S_%f")[:-3]
        parts = [kind, ts]
        if score is not None:
            parts.append(f"sim{score:.2f}")
        if verdict:
            parts.append(_safe(verdict))
        path = os.path.join(folder, "_".join(parts) + ".wav")

        sf.write(path, np.asarray(audio, dtype=np.float32), sample_rate)
        print(f"[debug-audio] saved {path}")
        return path
    except Exception as exc:
        print(f"[debug-audio] save failed: {exc}")
        return None
