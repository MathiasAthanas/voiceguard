import logging
import os
import math
from pathlib import Path
from typing import Optional

import numpy as np
from scipy import signal
import torch
import torch.nn as nn
import torch.nn.functional as F
import torchaudio

logger = logging.getLogger(__name__)

SAMPLE_RATE = 16000
CLIP_SECONDS = 4.0
N_FFT = 400
HOP_LENGTH = 160
N_MELS = 64
FMIN = 20
FMAX = 7600
EPS = 1e-6
_MEL_TRANSFORM = None
_DB_TRANSFORM = None


def _model_path(env_name: str, relative_to_root: str) -> Optional[Path]:
    configured = os.getenv(env_name)
    if configured:
        return Path(configured)

    current = Path(__file__).resolve()
    candidates = [
        current.parents[4] / relative_to_root,
        current.parents[3] / relative_to_root,
        Path.cwd() / relative_to_root,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def _fixed_length_audio(audio: np.ndarray) -> np.ndarray:
    target_len = int(SAMPLE_RATE * CLIP_SECONDS)
    if audio.size == target_len:
        return audio.astype(np.float32)
    if audio.size < target_len:
        pad = target_len - audio.size
        left = pad // 2
        right = pad - left
        return np.pad(audio, (left, right), mode="constant").astype(np.float32)
    start = max((audio.size - target_len) // 2, 0)
    return audio[start : start + target_len].astype(np.float32)


def audio_to_logmel(audio: np.ndarray) -> np.ndarray:
    global _MEL_TRANSFORM, _DB_TRANSFORM
    audio = _fixed_length_audio(audio.astype(np.float32))
    if _MEL_TRANSFORM is None:
        _MEL_TRANSFORM = torchaudio.transforms.MelSpectrogram(
            sample_rate=SAMPLE_RATE,
            n_fft=N_FFT,
            win_length=N_FFT,
            hop_length=HOP_LENGTH,
            f_min=FMIN,
            f_max=FMAX,
            n_mels=N_MELS,
            power=2.0,
            center=True,
            pad_mode="constant",
            norm="slaney",
            mel_scale="slaney",
        )
        _DB_TRANSFORM = torchaudio.transforms.AmplitudeToDB(
            stype="power",
            top_db=80,
        )

    tensor = torch.from_numpy(audio)
    with torch.no_grad():
        logmel = _DB_TRANSFORM(_MEL_TRANSFORM(tensor))
        logmel = (logmel - logmel.mean()) / (logmel.std(unbiased=False) + EPS)
    return logmel.cpu().numpy().astype(np.float32)


def _resample_audio(audio: np.ndarray, orig_sr: int) -> np.ndarray:
    gcd = math.gcd(orig_sr, SAMPLE_RATE)
    up = SAMPLE_RATE // gcd
    down = orig_sr // gcd
    return signal.resample_poly(audio.astype(np.float32), up, down).astype(np.float32)


class CNNLSTMv2(nn.Module):
    def __init__(self, lstm_hidden: int = 64, dropout: float = 0.45) -> None:
        super().__init__()
        self.cnn = nn.Sequential(
            nn.Conv2d(1, 16, kernel_size=3, padding=1),
            nn.BatchNorm2d(16),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=(2, 1)),
            nn.Dropout2d(dropout * 0.35),
            nn.Conv2d(16, 24, kernel_size=3, padding=1),
            nn.BatchNorm2d(24),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=(2, 1)),
            nn.Dropout2d(dropout * 0.45),
            nn.Conv2d(24, 32, kernel_size=3, padding=1),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=(2, 1)),
            nn.Dropout2d(dropout * 0.55),
        )
        self.lstm = nn.LSTM(
            input_size=32 * 8,
            hidden_size=lstm_hidden,
            num_layers=1,
            batch_first=True,
            bidirectional=True,
        )
        self.classifier = nn.Sequential(
            nn.LayerNorm(lstm_hidden * 2),
            nn.Linear(lstm_hidden * 2, 64),
            nn.ReLU(inplace=True),
            nn.Dropout(dropout),
            nn.Linear(64, 2),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.cnn(x)
        batch, channels, mel_bins, frames = x.shape
        x = x.permute(0, 3, 1, 2).contiguous()
        x = x.view(batch, frames, channels * mel_bins)
        output, _ = self.lstm(x)
        mean_pool = torch.mean(output, dim=1)
        max_pool, _ = torch.max(output, dim=1)
        return self.classifier(0.5 * (mean_pool + max_pool))


class SpeakerEmbeddingNet(nn.Module):
    def __init__(self, embedding_dim: int = 128, lstm_hidden: int = 96, dropout: float = 0.35) -> None:
        super().__init__()
        self.cnn = nn.Sequential(
            nn.Conv2d(1, 16, kernel_size=3, padding=1),
            nn.BatchNorm2d(16),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=(2, 1)),
            nn.Dropout2d(dropout * 0.35),
            nn.Conv2d(16, 32, kernel_size=3, padding=1),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=(2, 1)),
            nn.Dropout2d(dropout * 0.45),
            nn.Conv2d(32, 48, kernel_size=3, padding=1),
            nn.BatchNorm2d(48),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=(2, 1)),
        )
        self.lstm = nn.LSTM(
            input_size=48 * 8,
            hidden_size=lstm_hidden,
            num_layers=1,
            batch_first=True,
            bidirectional=True,
        )
        self.projection = nn.Sequential(
            nn.LayerNorm(lstm_hidden * 2),
            nn.Linear(lstm_hidden * 2, embedding_dim),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.cnn(x)
        batch, channels, mel_bins, frames = x.shape
        x = x.permute(0, 3, 1, 2).contiguous()
        x = x.view(batch, frames, channels * mel_bins)
        output, _ = self.lstm(x)
        pooled = torch.mean(output, dim=1)
        embedding = self.projection(pooled)
        return F.normalize(embedding, p=2, dim=1)


class CNNLSTMAntiSpoofModel:
    def __init__(self) -> None:
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model: Optional[CNNLSTMv2] = None
        # Env var is the authoritative source; default is 0.32 (raised from
        # the training default of 0.20 to reduce the false-reject rate on
        # real callers while keeping the false-accept rate acceptable).
        _env_threshold = os.getenv("CNN_LSTM_SPOOF_THRESHOLD")
        self.threshold = float(_env_threshold) if _env_threshold else 0.32
        self._threshold_from_env = _env_threshold is not None
        self.available = False
        self._load()

    def _load(self) -> None:
        path = _model_path(
            "CNN_LSTM_V2_MODEL_PATH",
            "aiworks/models/cnn_lstm_v2/best_model.pt",
        )
        if not path or not path.exists():
            logger.warning("CNN+LSTM anti-spoofing model not found: %s", path)
            return

        checkpoint = torch.load(str(path), map_location=self.device)
        config = checkpoint.get("config", {})
        # Only inherit the checkpoint threshold when the operator has NOT
        # explicitly set CNN_LSTM_SPOOF_THRESHOLD — the env var always wins.
        if not self._threshold_from_env:
            self.threshold = float(checkpoint.get("threshold", self.threshold))
        self.model = CNNLSTMv2(
            lstm_hidden=int(config.get("lstm_hidden", 64)),
            dropout=float(config.get("dropout", 0.45)),
        ).to(self.device)
        self.model.load_state_dict(checkpoint["model_state_dict"])
        self.model.eval()
        self.available = True
        logger.info("Loaded CNN+LSTM anti-spoofing model from %s", path)

    def predict(self, audio: np.ndarray, sample_rate: int = SAMPLE_RATE) -> dict:
        if not self.available or self.model is None:
            return {
                "available": False,
                "is_spoof": False,
                "spoof_probability": 0.0,
                "real_probability": 1.0,
                "label": "unavailable",
                "confidence": 0.0,
            }

        if sample_rate != SAMPLE_RATE:
            audio = _resample_audio(audio, sample_rate)
        feature = audio_to_logmel(audio)
        tensor = torch.from_numpy(feature).unsqueeze(0).unsqueeze(0).float().to(self.device)
        with torch.no_grad():
            logits = self.model(tensor)
            probabilities = torch.softmax(logits, dim=1).squeeze(0).cpu().numpy()

        real_probability = float(probabilities[0])
        spoof_probability = float(probabilities[1])
        is_spoof = spoof_probability >= self.threshold
        return {
            "available": True,
            "is_spoof": bool(is_spoof),
            "spoof_probability": spoof_probability,
            "real_probability": real_probability,
            "label": "cloned" if is_spoof else "real",
            "confidence": spoof_probability if is_spoof else real_probability,
            "threshold": self.threshold,
            "model": "cnn_lstm_v2",
        }


class CNNLSTMSpeakerEmbeddingModel:
    def __init__(self) -> None:
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model: Optional[SpeakerEmbeddingNet] = None
        self.threshold = float(os.getenv("CNN_LSTM_SPEAKER_THRESHOLD", "0.62"))
        self.available = False
        self._load()

    def _load(self) -> None:
        path = _model_path(
            "SPEAKER_EMBEDDING_MODEL_PATH",
            "aiworks/models/speaker_embedding/best_model.pt",
        )
        if not path or not path.exists():
            logger.warning("CNN+LSTM speaker embedding model not found: %s", path)
            return

        checkpoint = torch.load(str(path), map_location=self.device)
        config = checkpoint.get("config", {})
        self.threshold = float(checkpoint.get("threshold", self.threshold))
        self.model = SpeakerEmbeddingNet(
            embedding_dim=int(checkpoint.get("embedding_dim", config.get("embedding_dim", 128))),
            lstm_hidden=int(config.get("lstm_hidden", 96)),
            dropout=float(config.get("dropout", 0.35)),
        ).to(self.device)
        self.model.load_state_dict(checkpoint["model_state_dict"])
        self.model.eval()
        self.available = True
        logger.info("Loaded CNN+LSTM speaker embedding model from %s", path)

    def get_embedding(self, audio: np.ndarray, sample_rate: int = SAMPLE_RATE) -> np.ndarray:
        if not self.available or self.model is None:
            raise RuntimeError("CNN+LSTM speaker embedding model not loaded")
        if sample_rate != SAMPLE_RATE:
            audio = _resample_audio(audio, sample_rate)
        feature = audio_to_logmel(audio)
        tensor = torch.from_numpy(feature).unsqueeze(0).unsqueeze(0).float().to(self.device)
        with torch.no_grad():
            embedding = self.model(tensor).squeeze(0).cpu().numpy().astype(np.float32)
        return embedding

    def compute_similarity(self, embedding1: np.ndarray, embedding2: np.ndarray) -> float:
        norm1 = float(np.linalg.norm(embedding1))
        norm2 = float(np.linalg.norm(embedding2))
        if norm1 == 0.0 or norm2 == 0.0:
            return 0.0
        return float(np.dot(embedding1, embedding2) / (norm1 * norm2))

    def verify(self, enrolled_embedding: np.ndarray, test_audio: np.ndarray, sample_rate: int = SAMPLE_RATE) -> dict:
        test_embedding = self.get_embedding(test_audio, sample_rate)
        similarity = self.compute_similarity(enrolled_embedding, test_embedding)
        confidence = (similarity + 1.0) / 2.0
        return {
            "available": True,
            "similarity_score": float(similarity),
            "confidence": float(confidence),
            "is_same_speaker": bool(similarity >= self.threshold),
            "threshold_used": self.threshold,
            "model": "cnn_lstm_speaker_embedding",
        }


_anti_spoof_instance: Optional[CNNLSTMAntiSpoofModel] = None
_speaker_embedding_instance: Optional[CNNLSTMSpeakerEmbeddingModel] = None


def get_cnn_lstm_antispoof_model() -> CNNLSTMAntiSpoofModel:
    global _anti_spoof_instance
    if _anti_spoof_instance is None:
        _anti_spoof_instance = CNNLSTMAntiSpoofModel()
    return _anti_spoof_instance


def get_cnn_lstm_speaker_embedding_model() -> CNNLSTMSpeakerEmbeddingModel:
    global _speaker_embedding_instance
    if _speaker_embedding_instance is None:
        _speaker_embedding_instance = CNNLSTMSpeakerEmbeddingModel()
    return _speaker_embedding_instance
