"""TitaNet-Large speaker verification backend (Fix 4).

nvidia/speakerverification_en_titanet_large — 23M params, 192-dim embeddings,
0.66% EER on VoxCeleb1-O. Crucially it is trained on Fisher and Switchboard
(conversational *telephone* corpora) in addition to VoxCeleb, making it a much
closer domain match for cellular-call verification than WavLM-Base+ (clean /
wideband pretraining).

This wrapper exposes the SAME interface as WavLMSpeakerModel so it is a drop-in
backend behind get_ecapa_model():  get_embedding / compute_similarity / verify /
verify_set, plus an `embedding_dim` attribute used for the stale-voiceprint
check.

Requires NeMo:  pip install nemo_toolkit[asr]
NeMo is imported lazily inside _load() so importing this module never fails even
when NeMo is absent — the factory checks `model is not None` and falls back.
"""

import logging
import os
import tempfile

import numpy as np

logger = logging.getLogger(__name__)

TITANET_MODEL_ID = os.getenv(
    "TITANET_MODEL_ID", "nvidia/speakerverification_en_titanet_large"
)


class TitaNetSpeakerModel:
    """NeMo TitaNet-Large speaker embedding model, WavLM-compatible interface."""

    def __init__(self):
        self.model = None
        self.embedding_dim = 192
        self.device = "cpu"
        self._load()

    def _load(self):
        try:
            import torch  # noqa: PLC0415
            import nemo.collections.asr as nemo_asr  # noqa: PLC0415

            self.device = "cuda" if torch.cuda.is_available() else "cpu"
            print(f"Loading TitaNet-Large speaker model ({TITANET_MODEL_ID})...")
            self.model = nemo_asr.models.EncDecSpeakerLabelModel.from_pretrained(
                model_name=TITANET_MODEL_ID
            )
            self.model.eval()
            self.model.to(self.device)
            print(f"TitaNet-Large speaker model loaded on {self.device}")
        except Exception as exc:
            print(f"Warning: Could not load TitaNet model: {exc}")
            print("Install NeMo with: pip install nemo_toolkit[asr]")
            self.model = None

    def get_embedding(self, audio: np.ndarray, sample_rate: int = 16000) -> np.ndarray:
        if self.model is None:
            raise RuntimeError("TitaNet speaker model not loaded")

        rms = float(np.sqrt(np.mean(audio ** 2)))
        if rms < 0.001:
            raise ValueError("Audio is silent — no speech detected")

        # NeMo's get_embedding consumes a file path; write a short-lived temp WAV.
        import soundfile as sf  # noqa: PLC0415

        fd, tmp_path = tempfile.mkstemp(suffix=".wav")
        try:
            os.close(fd)
            sf.write(tmp_path, np.asarray(audio, dtype=np.float32), sample_rate)
            emb = self.model.get_embedding(tmp_path).squeeze().detach().cpu().numpy()
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

        emb = emb.astype(np.float32)
        norm = np.linalg.norm(emb)
        if norm > 0:
            emb = emb / norm
        return emb

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
        """Score-averaged verification against a (N, D) template set (Fix 2)."""
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
