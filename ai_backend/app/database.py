"""
Persistent SQLite store for VoiceGuard dashboard history.
All functions are synchronous and safe to call from run_in_executor.
"""

import datetime
import os
import sqlite3
import time
from typing import Any, Dict

DB_PATH = os.getenv("DASHBOARD_DB", "dashboard.db")


# ── connection ────────────────────────────────────────────────────────────────

def _conn() -> sqlite3.Connection:
    c = sqlite3.connect(DB_PATH, check_same_thread=False)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA synchronous=NORMAL")
    return c


# ── schema ────────────────────────────────────────────────────────────────────

def init_db() -> None:
    with _conn() as c:
        c.executescript("""
            CREATE TABLE IF NOT EXISTS verification_events (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp         REAL    NOT NULL,
                contact_id        TEXT    NOT NULL,
                verdict           TEXT    NOT NULL,
                spoof_probability REAL    DEFAULT 0.0,
                similarity_score  REAL,
                confidence        REAL    DEFAULT 0.0
            );
            CREATE TABLE IF NOT EXISTS call_events (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                room_id    TEXT    NOT NULL UNIQUE,
                caller     TEXT    NOT NULL,
                callee     TEXT    NOT NULL,
                started_at REAL    NOT NULL,
                ended_at   REAL
            );
            CREATE TABLE IF NOT EXISTS enrollment_events (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp  REAL    NOT NULL,
                contact_id TEXT    NOT NULL,
                success    INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_verif_ts ON verification_events(timestamp);
            CREATE INDEX IF NOT EXISTS idx_call_ts  ON call_events(started_at);
        """)


# ── writes ────────────────────────────────────────────────────────────────────

def insert_verification(
    timestamp: float,
    contact_id: str,
    verdict: str,
    spoof_probability: float,
    similarity_score,
    confidence: float,
) -> None:
    with _conn() as c:
        c.execute(
            """INSERT INTO verification_events
               (timestamp, contact_id, verdict, spoof_probability, similarity_score, confidence)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (timestamp, contact_id, verdict, spoof_probability, similarity_score, confidence),
        )


def insert_call_start(room_id: str, caller: str, callee: str, started_at: float) -> None:
    with _conn() as c:
        c.execute(
            """INSERT OR REPLACE INTO call_events (room_id, caller, callee, started_at)
               VALUES (?, ?, ?, ?)""",
            (room_id, caller, callee, started_at),
        )


def update_call_end(room_id: str, ended_at: float) -> None:
    with _conn() as c:
        c.execute(
            "UPDATE call_events SET ended_at=? WHERE room_id=? AND ended_at IS NULL",
            (ended_at, room_id),
        )


def insert_enrollment(timestamp: float, contact_id: str, success: bool) -> None:
    with _conn() as c:
        c.execute(
            "INSERT INTO enrollment_events (timestamp, contact_id, success) VALUES (?, ?, ?)",
            (timestamp, contact_id, int(success)),
        )


# ── reads ─────────────────────────────────────────────────────────────────────

def get_totals() -> Dict[str, int]:
    with _conn() as c:
        return {
            "total_verifications": c.execute(
                "SELECT COUNT(*) FROM verification_events"
            ).fetchone()[0],
            "total_spoofs": c.execute(
                "SELECT COUNT(*) FROM verification_events WHERE verdict='spoof_detected'"
            ).fetchone()[0],
            "total_verified": c.execute(
                "SELECT COUNT(*) FROM verification_events WHERE verdict IN ('verified','verified_high')"
            ).fetchone()[0],
            "total_enrollments": c.execute(
                "SELECT COUNT(*) FROM enrollment_events WHERE success=1"
            ).fetchone()[0],
        }


def get_chart_data(hours: int = 24, days: int = 7) -> Dict[str, Any]:
    now = time.time()

    with _conn() as c:
        # ── hourly verification / spoof buckets ───────────────────────────────
        since_h = now - hours * 3600
        rows = c.execute(
            """
            SELECT
                CAST(timestamp / 3600 AS INTEGER) * 3600 AS bucket,
                COUNT(*) AS total,
                SUM(CASE WHEN verdict='spoof_detected' THEN 1 ELSE 0 END) AS spoofs
            FROM verification_events
            WHERE timestamp >= ?
            GROUP BY bucket
            ORDER BY bucket
            """,
            (since_h,),
        ).fetchall()
        bucket_map = {r["bucket"]: (r["total"], r["spoofs"]) for r in rows}

        hour_labels, hour_verifs, hour_spoofs = [], [], []
        for i in range(hours - 1, -1, -1):
            ts = int((now - i * 3600) / 3600) * 3600
            hour_labels.append(datetime.datetime.fromtimestamp(ts).strftime("%H:%M"))
            v, s = bucket_map.get(ts, (0, 0))
            hour_verifs.append(v)
            hour_spoofs.append(s)

        # ── daily call buckets ────────────────────────────────────────────────
        since_d = now - days * 86400
        day_rows = c.execute(
            """
            SELECT
                CAST(started_at / 86400 AS INTEGER) * 86400 AS bucket,
                COUNT(*) AS total
            FROM call_events
            WHERE started_at >= ?
            GROUP BY bucket
            ORDER BY bucket
            """,
            (since_d,),
        ).fetchall()
        day_map = {r["bucket"]: r["total"] for r in day_rows}

        day_labels, day_counts = [], []
        for i in range(days - 1, -1, -1):
            ts = int((now - i * 86400) / 86400) * 86400
            day_labels.append(datetime.datetime.fromtimestamp(ts).strftime("%a %d"))
            day_counts.append(day_map.get(ts, 0))

    return {
        "hourly": {
            "labels": hour_labels,
            "verifications": hour_verifs,
            "spoofs": hour_spoofs,
        },
        "daily_calls": {
            "labels": day_labels,
            "counts": day_counts,
        },
    }
