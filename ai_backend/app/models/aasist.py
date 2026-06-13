from typing import Optional

import numpy as np

from app.models.cnn_lstm_voiceguard import get_cnn_lstm_antispoof_model


class AASISTWrapper:
    """Compatibility wrapper for the active anti-spoofing model."""

    def __init__(self):
        self.model = get_cnn_lstm_antispoof_model()
        self.available = self.model.available

    def predict(self, audio: np.ndarray, sample_rate: int = 16000) -> dict:
        result = self.model.predict(audio, sample_rate=sample_rate)
        self.available = result.get("available", False)
        return result


_instance: Optional[AASISTWrapper] = None


def get_aasist_model() -> AASISTWrapper:
    global _instance
    if _instance is None:
        _instance = AASISTWrapper()
    return _instance
