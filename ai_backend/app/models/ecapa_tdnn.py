import os

import numpy as np
import torch
import torch.nn.functional as F
from transformers import Wav2Vec2FeatureExtractor, WavLMForXVector

# Override via WAVLM_MODEL_ID env var if the default ID changes on HuggingFace.
WAVLM_MODEL_ID = os.getenv("WAVLM_MODEL_ID", "microsoft/wavlm-base-plus-sv")

# ECAPA-TDNN produced 192-dim embeddings. WavLM produces 512-dim.
# Any voiceprint with 192 dims was enrolled under the old model and is stale.
ECAPA_LEGACY_DIM = 192


class WavLMSpeakerModel:
    """
    WavLM-Base+ speaker verification model (replaces ECAPA-TDNN).

    WavLM was pretrained with a masked-speech denoising objective, making its
    representations inherently robust to codec compression, bandpass filtering,
    and AGC effects present in cellular/VoIP audio — the exact conditions where
    ECAPA-TDNN (trained on clean VoxCeleb) produced inverted verdicts.

    Embedding dimension: 512 (vs ECAPA's 192).
    All contacts enrolled with ECAPA must be re-enrolled.
    """

    def __init__(self):
        self.model = None
        self.feature_extractor = None
        self.embedding_dim = 512
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self._load_model()

    def _load_model(self):
        try:
            print(f"Loading WavLM speaker verification model ({WAVLM_MODEL_ID})...")
            weights_dir = os.path.join(
                os.getenv("WEIGHTS_DIR", "weights"), "wavlm_speaker"
            )
            self.feature_extractor = Wav2Vec2FeatureExtractor.from_pretrained(
                WAVLM_MODEL_ID, cache_dir=weights_dir
            )
            self.model = WavLMForXVector.from_pretrained(
                WAVLM_MODEL_ID, cache_dir=weights_dir
            )
            self.model.eval()
            self.model.to(self.device)
            print(f"WavLM speaker model loaded on {self.device}")
            print(
                "IMPORTANT: ECAPA voiceprints (192-dim) are incompatible with WavLM. "
                "All contacts must be re-enrolled."
            )
        except Exception as e:
            print(f"Warning: Could not load WavLM model: {e}")
            print(
                f"Check that '{WAVLM_MODEL_ID}' is a valid HuggingFace model ID, "
                "or override with the WAVLM_MODEL_ID environment variable."
            )
            self.model = None
            self.feature_extractor = None

    def get_embedding(self, audio: np.ndarray, sample_rate: int = 16000) -> np.ndarray:
        if self.model is None or self.feature_extractor is None:
            raise RuntimeError("WavLM speaker model not loaded")

        rms = float(np.sqrt(np.mean(audio ** 2)))
        if rms < 0.001:
            raise ValueError("Audio is silent — no speech detected")

        inputs = self.feature_extractor(
            audio,
            sampling_rate=sample_rate,
            return_tensors="pt",
            padding=True,
        )
        inputs = {k: v.to(self.device) for k, v in inputs.items()}

        with torch.no_grad():
            outputs = self.model(**inputs)
            embedding = outputs.embeddings  # shape: (1, embedding_dim)

        embedding = F.normalize(embedding, dim=-1)
        return embedding.squeeze().cpu().numpy()

    def compute_similarity(
        self, embedding1: np.ndarray, embedding2: np.ndarray
    ) -> float:
        if embedding1.shape != embedding2.shape:
            raise ValueError(
                f"Embedding shape mismatch ({embedding1.shape} vs {embedding2.shape}). "
                "Contact was likely enrolled with a different model — please re-enroll."
            )
        norm1 = np.linalg.norm(embedding1)
        norm2 = np.linalg.norm(embedding2)
        if norm1 == 0 or norm2 == 0:
            return 0.0
        return float(np.dot(embedding1, embedding2) / (norm1 * norm2))

    def verify(
        self,
        enrolled_embedding: np.ndarray,
        test_audio: np.ndarray,
        threshold: float = 0.75,
        sample_rate: int = 16000,
    ) -> dict:
        test_embedding = self.get_embedding(test_audio, sample_rate)
        similarity = self.compute_similarity(enrolled_embedding, test_embedding)
        confidence = (similarity + 1) / 2

        return {
            "similarity_score": float(similarity),
            "confidence": float(confidence),
            "is_same_speaker": bool(similarity >= threshold),
            "threshold_used": threshold,
        }

    def verify_set(
        self,
        enrolled_embeddings: np.ndarray,
        test_audio: np.ndarray,
        threshold: float = 0.75,
        sample_rate: int = 16000,
    ) -> dict:
        """Score-averaged verification against a (N, D) template set (Fix 2).

        Computes one cosine similarity per stored enrollment template and
        averages the SCORES (not the embeddings). Score-level fusion keeps a
        similar-voiced impostor from hiding near a single averaged centroid:
        the impostor must score above threshold against the templates *on
        average*, which is harder than landing near their mean.
        """
        test_embedding = self.get_embedding(test_audio, sample_rate)
        matrix = (
            enrolled_embeddings
            if enrolled_embeddings.ndim == 2
            else enrolled_embeddings.reshape(1, -1)
        )
        sims = np.asarray(
            [self.compute_similarity(row, test_embedding) for row in matrix],
            dtype=np.float32,
        )
        similarity = float(np.mean(sims))
        confidence = (similarity + 1) / 2
        return {
            "similarity_score": similarity,
            "confidence": float(confidence),
            "is_same_speaker": bool(similarity >= threshold),
            "threshold_used": threshold,
            "per_template_scores": [float(s) for s in sims],
            "max_template_score": float(np.max(sims)),
            "num_templates": int(matrix.shape[0]),
        }


_instance = None


def get_ecapa_model():
    """Return the configured speaker-verification backend (singleton).

    SPEAKER_MODEL selects the backend:
      wavlm     (default) — WavLM-Base+ (wideband; weak on ≤4 kHz telephone audio)
      wespeaker            — WeSpeaker ResNet34-LM / eRes2Net (telephone-robust)
      titanet             — TitaNet-Large (NeMo; telephone-domain)
    A requested backend that fails to load (missing package / download) falls
    back to WavLM so the service still starts. Switching backend changes the
    embedding space — re-enroll all contacts after switching.
    """
    global _instance
    if _instance is None:
        backend = os.getenv("SPEAKER_MODEL", "wavlm").strip().lower()
        if backend == "wespeaker":
            try:
                from app.models.wespeaker_model import WeSpeakerModel
                candidate = WeSpeakerModel()
                if getattr(candidate, "model", None) is not None:
                    _instance = candidate
                    return _instance
                print("WeSpeaker unavailable — falling back to WavLM-Base+")
            except Exception as exc:
                print(f"WeSpeaker load failed ({exc}) — falling back to WavLM-Base+")
        elif backend == "titanet":
            try:
                from app.models.titanet import TitaNetSpeakerModel
                candidate = TitaNetSpeakerModel()
                if getattr(candidate, "model", None) is not None:
                    _instance = candidate
                    return _instance
                print("TitaNet unavailable — falling back to WavLM-Base+")
            except Exception as exc:
                print(f"TitaNet load failed ({exc}) — falling back to WavLM-Base+")
        _instance = WavLMSpeakerModel()
    return _instance
