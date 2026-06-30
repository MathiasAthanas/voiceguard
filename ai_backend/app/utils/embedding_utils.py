import numpy as np
import os
import json


VOICEPRINTS_DIR = os.getenv("VOICEPRINTS_DIR", "voiceprints")
SPEAKER_EMBEDDING_SUFFIX = ".cnn_lstm.npy"


def save_voiceprint(contact_id: str, embedding: np.ndarray):
    """Save a speaker embedding (voiceprint) to disk.

    Accepts either a single embedding (shape (D,)) or a stacked template set
    (shape (N, D)). The on-disk format is just the numpy array, so the same
    file transparently holds legacy single-vector and new multi-template
    voiceprints — load_voiceprint + as_embedding_matrix normalise the shape.
    """
    os.makedirs(VOICEPRINTS_DIR, exist_ok=True)
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}.npy")
    np.save(path, np.asarray(embedding, dtype=np.float32))


def save_voiceprint_set(contact_id: str, embeddings: list):
    """Save a set of enrollment templates as a stacked (N, D) array (Fix 2).

    Score-level averaging across separate templates outperforms averaging the
    embeddings into a single centroid for modern deep speaker models, because a
    similar-voiced impostor can sit near the centroid yet still score below each
    individual template.
    """
    stacked = np.stack([np.asarray(e, dtype=np.float32) for e in embeddings], axis=0)
    save_voiceprint(contact_id, stacked)


def as_embedding_matrix(arr: np.ndarray) -> np.ndarray:
    """Normalise a loaded voiceprint to a 2-D (N, D) template matrix.

    Legacy single-vector voiceprints (shape (D,)) become (1, D); new stacked
    sets (shape (N, D)) pass through unchanged.
    """
    a = np.asarray(arr)
    return a.reshape(1, -1) if a.ndim == 1 else a


def save_secondary_voiceprint(contact_id: str, embedding: np.ndarray):
    """Save the CNN+LSTM speaker embedding voiceprint."""
    os.makedirs(VOICEPRINTS_DIR, exist_ok=True)
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}{SPEAKER_EMBEDDING_SUFFIX}")
    np.save(path, embedding)


def load_voiceprint(contact_id: str) -> np.ndarray:
    """Load a saved speaker embedding from disk."""
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}.npy")
    if not os.path.exists(path):
        raise FileNotFoundError(f"No voiceprint found for contact: {contact_id}")
    return np.load(path)


def load_secondary_voiceprint(contact_id: str) -> np.ndarray:
    """Load the CNN+LSTM speaker embedding voiceprint."""
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}{SPEAKER_EMBEDDING_SUFFIX}")
    if not os.path.exists(path):
        raise FileNotFoundError(f"No secondary voiceprint found for contact: {contact_id}")
    return np.load(path)


def voiceprint_exists(contact_id: str) -> bool:
    """Check if a voiceprint exists for this contact."""
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}.npy")
    return os.path.exists(path)


def secondary_voiceprint_exists(contact_id: str) -> bool:
    """Check if the CNN+LSTM speaker embedding voiceprint exists."""
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}{SPEAKER_EMBEDDING_SUFFIX}")
    return os.path.exists(path)


def delete_voiceprint(contact_id: str) -> bool:
    """Delete a voiceprint from disk."""
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}.npy")
    secondary_path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}{SPEAKER_EMBEDDING_SUFFIX}")
    deleted = False
    if os.path.exists(path):
        os.remove(path)
        deleted = True
    if os.path.exists(secondary_path):
        os.remove(secondary_path)
        deleted = True
    return deleted


def list_enrolled_contacts() -> list:
    """Return list of all enrolled contact IDs."""
    if not os.path.exists(VOICEPRINTS_DIR):
        return []
    files = os.listdir(VOICEPRINTS_DIR)
    contacts = []
    for file_name in files:
        if not file_name.endswith(".npy"):
            continue
        if file_name.endswith(SPEAKER_EMBEDDING_SUFFIX):
            continue
        contacts.append(file_name.replace(".npy", ""))
    return contacts


def average_embeddings(embeddings: list) -> np.ndarray:
    """
    Average multiple embeddings into one.
    Used when enrolling with multiple voice samples
    to produce a more robust voiceprint.
    """
    stacked = np.stack(embeddings, axis=0)
    avg = np.mean(stacked, axis=0)
    # Re-normalize
    norm = np.linalg.norm(avg)
    if norm > 0:
        avg = avg / norm
    return avg
