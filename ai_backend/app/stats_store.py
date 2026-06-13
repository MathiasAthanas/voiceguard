import asyncio
import time
from collections import deque
from dataclasses import dataclass
from typing import Dict, List, Optional

import app.database as db


@dataclass
class VerificationEvent:
    timestamp: float
    contact_id: str
    verdict: str
    spoof_probability: float
    similarity_score: Optional[float]
    confidence: float


@dataclass
class ActiveCall:
    room_id: str
    caller: str
    callee: str
    started_at: float


@dataclass
class EnrollmentEvent:
    timestamp: float
    contact_id: str
    success: bool


class StatsStore:
    def __init__(self, max_events: int = 100) -> None:
        self._lock = asyncio.Lock()
        # These are loaded from DB on initialize() so they survive restarts
        self.total_verifications: int = 0
        self.total_spoofs: int = 0
        self.total_verified: int = 0
        self.total_enrollments: int = 0
        # In-memory only (recent events for live feed)
        self._verification_events: deque = deque(maxlen=max_events)
        self._active_calls: Dict[str, ActiveCall] = {}
        self._enrollment_events: deque = deque(maxlen=50)
        self._subscribers: List[asyncio.Queue] = []

    # ── startup ───────────────────────────────────────────────────────────────

    async def initialize(self) -> None:
        """Load persistent totals from SQLite so counters survive restarts."""
        loop = asyncio.get_running_loop()
        totals = await loop.run_in_executor(None, db.get_totals)
        async with self._lock:
            self.total_verifications = totals["total_verifications"]
            self.total_spoofs = totals["total_spoofs"]
            self.total_verified = totals["total_verified"]
            self.total_enrollments = totals["total_enrollments"]

    # ── record events ─────────────────────────────────────────────────────────

    async def record_verification(self, contact_id: str, result: dict) -> None:
        now = time.time()
        verdict = result.get("verdict", "unknown")
        event = VerificationEvent(
            timestamp=now,
            contact_id=contact_id,
            verdict=verdict,
            spoof_probability=result.get("spoof_probability", 0.0),
            similarity_score=result.get("similarity_score"),
            confidence=result.get("confidence", 0.0),
        )

        async with self._lock:
            self.total_verifications += 1
            if verdict == "spoof_detected":
                self.total_spoofs += 1
            elif verdict in ("verified", "verified_high"):
                self.total_verified += 1
            self._verification_events.appendleft(event)

        loop = asyncio.get_running_loop()
        await loop.run_in_executor(
            None,
            db.insert_verification,
            now, contact_id, verdict,
            event.spoof_probability, event.similarity_score, event.confidence,
        )
        await self._notify()

    async def record_call_start(self, room_id: str, caller: str, callee: str) -> None:
        now = time.time()
        async with self._lock:
            self._active_calls[room_id] = ActiveCall(
                room_id=room_id, caller=caller, callee=callee, started_at=now,
            )
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, db.insert_call_start, room_id, caller, callee, now)
        await self._notify()

    async def record_call_end(self, room_id: str) -> None:
        now = time.time()
        async with self._lock:
            self._active_calls.pop(room_id, None)
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, db.update_call_end, room_id, now)
        await self._notify()

    async def record_enrollment(self, contact_id: str, success: bool) -> None:
        now = time.time()
        event = EnrollmentEvent(timestamp=now, contact_id=contact_id, success=success)
        async with self._lock:
            if success:
                self.total_enrollments += 1
            self._enrollment_events.appendleft(event)
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, db.insert_enrollment, now, contact_id, success)
        await self._notify()

    # ── pub/sub ───────────────────────────────────────────────────────────────

    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=4)
        self._subscribers.append(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        try:
            self._subscribers.remove(q)
        except ValueError:
            pass

    async def _notify(self) -> None:
        for q in list(self._subscribers):
            try:
                q.put_nowait("update")
            except asyncio.QueueFull:
                pass

    # ── snapshot ──────────────────────────────────────────────────────────────

    def snapshot(self, hub_stats: dict) -> dict:
        now = time.time()
        return {
            "online_users": hub_stats.get("online_users", 0),
            "users": hub_stats.get("users", []),
            "active_calls": len(self._active_calls),
            "active_call_list": [
                {
                    "room_id": c.room_id,
                    "caller": c.caller,
                    "callee": c.callee,
                    "duration": int(now - c.started_at),
                }
                for c in self._active_calls.values()
            ],
            "total_verifications": self.total_verifications,
            "total_spoofs": self.total_spoofs,
            "total_verified": self.total_verified,
            "total_enrollments": self.total_enrollments,
            "recent_verifications": [
                {
                    "timestamp": e.timestamp,
                    "contact_id": e.contact_id,
                    "verdict": e.verdict,
                    "spoof_probability": e.spoof_probability,
                    "similarity_score": e.similarity_score,
                    "confidence": e.confidence,
                }
                for e in list(self._verification_events)[:20]
            ],
            "recent_enrollments": [
                {
                    "timestamp": e.timestamp,
                    "contact_id": e.contact_id,
                    "success": e.success,
                }
                for e in list(self._enrollment_events)[:10]
            ],
        }


_store: Optional[StatsStore] = None


def get_stats_store() -> StatsStore:
    global _store
    if _store is None:
        _store = StatsStore()
    return _store
