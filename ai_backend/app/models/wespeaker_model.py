"""WeSpeaker speaker-verification backend (telephone-robust).

WeSpeaker models (ResNet34-LM / eRes2Net) are trained with large-margin softmax
on VoxCeleb and perform well on narrowband/telephone audio — exactly the
≤4 kHz cellular audio where WavLM-Base+ (wideband-trained) loses same-gender
discrimination. This is the recommended swap when the saved debug audio is band
-limited to 4 kHz and same-gender impostors pass.

Same interface as WavLMSpeakerModel so it's a drop-in behind get_ecapa_model():
get_embedding / compute_similarity / verify / verify_set, plus `embedding_dim`.

Install:  pip install git+https://github.com/wenet-e2e/wespeaker.git
Model:    set WESPEAKER_MODEL (a pretrained name like "english") OR
          WESPEAKER_MODEL_DIR (a local model directory).
NeMo is NOT required — pure PyTorch, works with the existing torch 2.4.

The heavy import is lazy (inside _load), so importing this module never fails
when wespeaker is absent — the factory checks `model is not None` and falls back.
"""

import logging
import os
import tempfile

import numpy as np

logger = logging.getLogger(__name__)

# ResNet34-LM emits 256-dim embeddings. If you switch WESPEAKER_MODEL to a
# variant with a different dim, re-enroll (the stale-voiceprint check compares
# this against the stored embedding dim).
WESPEAKER_EMBEDDING_DIM = int(os.getenv("WESPEAKER_EMBEDDING_DIM", "256"))


class WeSpeakerModel:
    """WeSpeaker speaker embedding model, WavLM-compatible interface."""

    def __init__(self):
        self.model = None
        self.embedding_dim = WESPEAKER_EMBEDDING_DIM
        self.device = "cpu"
        self._load()

    def _load(self):
        try:
            import torch  # noqa: PLC0415
            import wespeaker  # noqa: PLC0415

            # WeSpeaker's current Python extraction path computes features on
            # CPU and then calls the model directly. If the model is moved to
            # CUDA, extraction fails with a CPU/CUDA tensor mismatch. Keep this
            # backend on CPU for correctness; WavLM/CNN-LSTM can still use CUDA.
            self.device = os.getenv("WESPEAKER_DEVICE", "cpu").strip().lower()
            if self.device not in {"cpu", "cuda"}:
                self.device = "cpu"
            local_dir = os.getenv("WESPEAKER_MODEL_DIR")
            if local_dir:
                print(f"Loading WeSpeaker model from {local_dir} …")
                self.model = wespeaker.load_model_local(local_dir)
            else:
                name = os.getenv("WESPEAKER_MODEL", "english")
                print(f"Loading WeSpeaker pretrained model '{name}' …")
                self.model = wespeaker.load_model(name)
            try:
                self.model.set_device(self.device)
            except Exception:
                pass
            print(f"WeSpeaker model loaded on {self.device}")
        except Exception as exc:
            print(f"Warning: Could not load WeSpeaker model: {exc}")
            print("Install with: pip install wespeaker")
            self.model = None

    def get_embedding(self, audio: np.ndarray, sample_rate: int = 16000) -> np.ndarray:
        if self.model is None:
            raise RuntimeError("WeSpeaker model not loaded")

        rms = float(np.sqrt(np.mean(audio ** 2)))
        if rms < 0.001:
            raise ValueError("Audio is silent — no speech detected")

        # WeSpeaker's extract_embedding consumes a file path.
        import soundfile as sf  # noqa: PLC0415

        fd, tmp_path = tempfile.mkstemp(suffix=".wav")
        try:
            os.close(fd)
            sf.write(tmp_path, np.asarray(audio, dtype=np.float32), sample_rate)
            emb = self.model.extract_embedding(tmp_path)
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

        emb = np.asarray(emb, dtype=np.float32).squeeze()
        self.embedding_dim = int(emb.shape[-1])
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
        """Score-averaged verification against a (N, D) template set."""
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
