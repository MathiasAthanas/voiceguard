import numpy as np
import os
import json


VOICEPRINTS_DIR = os.getenv("VOICEPRINTS_DIR", "voiceprints")


def save_voiceprint(contact_id: str, embedding: np.ndarray):
    """Save a speaker embedding (voiceprint) to disk."""
    os.makedirs(VOICEPRINTS_DIR, exist_ok=True)
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}.npy")
    np.save(path, embedding)


def load_voiceprint(contact_id: str) -> np.ndarray:
    """Load a saved speaker embedding from disk."""
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}.npy")
    if not os.path.exists(path):
        raise FileNotFoundError(f"No voiceprint found for contact: {contact_id}")
    return np.load(path)


def voiceprint_exists(contact_id: str) -> bool:
    """Check if a voiceprint exists for this contact."""
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}.npy")
    return os.path.exists(path)


def delete_voiceprint(contact_id: str) -> bool:
    """Delete a voiceprint from disk."""
    path = os.path.join(VOICEPRINTS_DIR, f"{contact_id}.npy")
    if os.path.exists(path):
        os.remove(path)
        return True
    return False


def list_enrolled_contacts() -> list:
    """Return list of all enrolled contact IDs."""
    if not os.path.exists(VOICEPRINTS_DIR):
        return []
    files = os.listdir(VOICEPRINTS_DIR)
    return [f.replace(".npy", "") for f in files if f.endswith(".npy")]


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
