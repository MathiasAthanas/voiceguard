"""Speech enhancement preprocessing for verification audio (Fix 3).

Codec-degraded VOICE_DOWNLINK audio is enhanced with DeepFilterNet before
speaker-embedding extraction, to close the clean-enrollment / telephone-test
domain gap. The enhancer is:

  - Env-gated:   only runs when ENABLE_SPEECH_ENHANCEMENT=true.
  - Lazy-loaded: the (heavy) model is initialised on first use, not at import.
  - Fail-safe:   any failure (model not installed, init error, runtime error)
                 returns the original audio unchanged, so the verification
                 pipeline never breaks because of enhancement.

To enable:  pip install deepfilternet   and set ENABLE_SPEECH_ENHANCEMENT=true.
"""

import logging
import os

import numpy as np

logger = logging.getLogger(__name__)

# DeepFilterNet runs at 48 kHz internally; we resample to/from the app rate.
_DF_INTERNAL_SR = 48000

# Tri-state cache: None = not attempted, False = unavailable, tuple = (model, state).
_df = None


def _enhancement_enabled() -> bool:
    return os.getenv("ENABLE_SPEECH_ENHANCEMENT", "false").strip().lower() in (
        "1", "true", "yes", "on",
    )


def _get_df():
    """Lazy-load DeepFilterNet. Returns (model, df_state) or None on failure."""
    global _df
    if _df is not None:
        return _df if _df is not False else None
    try:
        from df.enhance import init_df  # noqa: PLC0415

        model, df_state, _ = init_df()
        _df = (model, df_state)
        logger.info("DeepFilterNet enhancement model loaded")
    except Exception as exc:
        logger.warning(
            "Speech enhancement requested but DeepFilterNet unavailable "
            "(pip install deepfilternet): %s", exc
        )
        _df = False
    return _df if _df is not False else None


def is_enhancement_active() -> bool:
    """True if enhancement is both enabled and the model is loadable."""
    return _enhancement_enabled() and _get_df() is not None


def maybe_enhance(audio: np.ndarray, sample_rate: int = 16000) -> np.ndarray:
    """Enhance [audio] if enabled and available; otherwise return it unchanged."""
    if not _enhancement_enabled() or audio is None or audio.size == 0:
        return audio

    df = _get_df()
    if df is None:
        return audio

    model, df_state = df
    try:
        import torch  # noqa: PLC0415
        from df.enhance import enhance as df_enhance  # noqa: PLC0415
        import torchaudio.functional as AF  # noqa: PLC0415

        wav = torch.from_numpy(np.asarray(audio, dtype=np.float32)).unsqueeze(0)
        if sample_rate != _DF_INTERNAL_SR:
            wav = AF.resample(wav, sample_rate, _DF_INTERNAL_SR)

        enhanced = df_enhance(model, df_state, wav)

        if sample_rate != _DF_INTERNAL_SR:
            enhanced = AF.resample(enhanced, _DF_INTERNAL_SR, sample_rate)
        return enhanced.squeeze(0).cpu().numpy().astype(np.float32)
    except Exception as exc:
        logger.warning("Speech enhancement failed, using original audio: %s", exc)
        return audio
