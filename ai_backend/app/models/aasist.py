"""
Lightweight anti-spoofing wrapper.

The heavy Spectra/Wav2Vec2 anti-spoofing model was too slow to load on the
current CPU-only local setup. Keep this wrapper non-blocking so the backend
starts quickly and ECAPA speaker verification can run normally.
"""

from typing import Optional

import numpy as np


class AASISTWrapper:
    """Non-blocking anti-spoofing placeholder."""

    def __init__(self):
        self.model = None
        self.available = False

    def predict(self, audio: np.ndarray, sample_rate: int = 16000) -> dict:
        return {
            "available": False,
            "is_spoof": False,
            "spoof_probability": 0.0,
            "real_probability": 1.0,
            "label": "unavailable",
            "confidence": 0.0,
        }


_instance: Optional[AASISTWrapper] = None


def get_aasist_model() -> AASISTWrapper:
    global _instance
    if _instance is None:
        _instance = AASISTWrapper()
    return _instance
