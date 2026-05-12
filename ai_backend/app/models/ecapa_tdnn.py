import torch
import numpy as np
import os

# SpeechBrain 1.0+ moved to speechbrain.inference; keep fallback for 0.5.x
try:
    from speechbrain.inference.speaker import SpeakerRecognition
except ImportError:
    from speechbrain.pretrained import SpeakerRecognition  # type: ignore


class ECAPATDNNModel:
    """
    ECAPA-TDNN Speaker Verification Model.
    Uses SpeechBrain's pretrained ECAPA-TDNN to extract
    speaker embeddings and compute similarity scores.
    """

    def __init__(self):
        self.model = None
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self._load_model()

    def _load_model(self):
        try:
            print("Loading ECAPA-TDNN speaker verification model...")
            self.model = SpeakerRecognition.from_hparams(
                source="speechbrain/spkrec-ecapa-voxceleb",
                savedir=os.path.join(os.getenv("WEIGHTS_DIR", "weights"), "ecapa_tdnn"),
                run_opts={"device": self.device},
            )
            print(f"ECAPA-TDNN loaded on {self.device}")
        except Exception as e:
            print(f"Warning: Could not load ECAPA-TDNN model: {e}")
            self.model = None

    def get_embedding(self, audio: np.ndarray, sample_rate: int = 16000) -> np.ndarray:
        """
        Extract speaker embedding from audio array.
        Returns a 192-dimensional embedding vector.
        """
        if self.model is None:
            raise RuntimeError("ECAPA-TDNN model not loaded")

        # Reject silent audio early
        rms = float(np.sqrt(np.mean(audio ** 2)))
        if rms < 0.001:
            raise ValueError("Audio is silent — no speech detected")

        audio_tensor = torch.FloatTensor(audio).unsqueeze(0).to(self.device)

        # wav_lens must be relative lengths in [0, 1] — full length = 1.0
        wav_lens = torch.ones(1).to(self.device)

        with torch.no_grad():
            embedding = self.model.encode_batch(audio_tensor, wav_lens)

        # encode_batch returns (batch, 1, embedding_dim) — squeeze to (embedding_dim,)
        return embedding.squeeze().cpu().numpy()

    def compute_similarity(self, embedding1: np.ndarray, embedding2: np.ndarray) -> float:
        """
        Compute cosine similarity between two speaker embeddings.
        Returns a score between -1 and 1 (higher = more similar).
        """
        norm1 = np.linalg.norm(embedding1)
        norm2 = np.linalg.norm(embedding2)

        if norm1 == 0 or norm2 == 0:
            return 0.0

        similarity = np.dot(embedding1, embedding2) / (norm1 * norm2)
        return float(similarity)

    def verify(
        self,
        enrolled_embedding: np.ndarray,
        test_audio: np.ndarray,
        threshold: float = 0.75,
        sample_rate: int = 16000,
    ) -> dict:
        """
        Verify if test audio matches enrolled speaker.
        Returns verification result with score and decision.
        """
        test_embedding = self.get_embedding(test_audio, sample_rate)
        similarity = self.compute_similarity(enrolled_embedding, test_embedding)

        # Normalize to 0-1 confidence range
        confidence = (similarity + 1) / 2

        return {
            "similarity_score": float(similarity),
            "confidence": float(confidence),
            "is_same_speaker": bool(similarity >= threshold),
            "threshold_used": threshold,
        }


# Singleton instance
_instance = None


def get_ecapa_model() -> ECAPATDNNModel:
    global _instance
    if _instance is None:
        _instance = ECAPATDNNModel()
    return _instance
