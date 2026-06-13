import asyncio
import time
from typing import Any, Dict, List, Optional
from uuid import uuid4

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
from app.stats_store import get_stats_store

router = APIRouter()


class RegisterRequest(BaseModel):
    userId: str


class CallUserRequest(BaseModel):
    calleeId: str
    callerId: str
    offer: Dict[str, Any]


class AnswerCallRequest(BaseModel):
    roomId: str
    callerId: str
    answer: Dict[str, Any]


class RejectCallRequest(BaseModel):
    roomId: str
    callerId: str


class EndCallRequest(BaseModel):
    roomId: str
    targetUserId: str


class IceCandidateRequest(BaseModel):
    roomId: str
    targetUserId: str
    candidate: Dict[str, Any]


class SignalingHub:
    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._websockets: Dict[str, WebSocket] = {}
        self._queues: Dict[str, asyncio.Queue] = {}
        self._last_seen: Dict[str, float] = {}
        self._rooms: Dict[str, Dict[str, str]] = {}

    async def register_http(self, user_id: str) -> Dict[str, Any]:
        async with self._lock:
            self._touch(user_id)
            self._queue_for(user_id)
            users = self._online_users_locked()
        await self._broadcast_user_list(users)
        return {"type": "registered", "userId": user_id, "transport": "http"}

    async def register_websocket(self, user_id: str, websocket: WebSocket) -> None:
        async with self._lock:
            self._touch(user_id)
            self._websockets[user_id] = websocket
            self._queue_for(user_id)
            users = self._online_users_locked()
        await self._send_to(user_id, {
            "type": "registered",
            "userId": user_id,
            "transport": "websocket",
        })
        await self._broadcast_user_list(users)

    async def unregister(self, user_id: str, websocket: Optional[WebSocket] = None) -> None:
        async with self._lock:
            current_ws = self._websockets.get(user_id)
            if websocket is None or current_ws is websocket:
                self._websockets.pop(user_id, None)
                self._last_seen.pop(user_id, None)
            users = self._online_users_locked()
        await self._broadcast_user_list(users)

    async def events(self, user_id: str, timeout: int = 20) -> Dict[str, Any]:
        async with self._lock:
            self._touch(user_id)
            queue = self._queue_for(user_id)
            users = self._online_users_locked()

        if queue.empty():
            await self._send_to(user_id, {"type": "user_list", "users": users})

        try:
            event = await asyncio.wait_for(queue.get(), timeout=max(1, min(timeout, 30)))
            events = [event]
            while not queue.empty():
                events.append(queue.get_nowait())
            return {"events": events}
        except asyncio.TimeoutError:
            async with self._lock:
                self._touch(user_id)
                users = self._online_users_locked()
            return {"events": [{"type": "user_list", "users": users}]}

    async def call_user(self, payload: CallUserRequest) -> None:
        async with self._lock:
            self._touch(payload.callerId)
            callee_online = self._is_online_locked(payload.calleeId)
            room_id = str(uuid4()) if callee_online else None
            if room_id:
                self._rooms[room_id] = {
                    "caller": payload.callerId,
                    "callee": payload.calleeId,
                }

        if not room_id:
            await self._send_to(payload.callerId, {
                "type": "call_failed",
                "reason": f"{payload.calleeId} is offline or not connected",
            })
            return

        await self._send_to(payload.calleeId, {
            "type": "incoming_call",
            "callerId": payload.callerId,
            "roomId": room_id,
            "offer": payload.offer,
        })
        await self._send_to(payload.callerId, {
            "type": "call_created",
            "roomId": room_id,
        })

    async def answer_call(self, payload: AnswerCallRequest) -> None:
        async with self._lock:
            room = dict(self._rooms.get(payload.roomId, {}))
        await self._send_to(payload.callerId, {
            "type": "call_answered",
            "roomId": payload.roomId,
            "answer": payload.answer,
        })
        await get_stats_store().record_call_start(
            payload.roomId,
            room.get("caller", payload.callerId),
            room.get("callee", "unknown"),
        )

    async def reject_call(self, payload: RejectCallRequest) -> None:
        await self._send_to(payload.callerId, {
            "type": "call_rejected",
            "roomId": payload.roomId,
        })
        async with self._lock:
            self._rooms.pop(payload.roomId, None)
        await get_stats_store().record_call_end(payload.roomId)

    async def end_call(self, payload: EndCallRequest) -> None:
        await self._send_to(payload.targetUserId, {
            "type": "call_ended",
            "roomId": payload.roomId,
        })
        async with self._lock:
            self._rooms.pop(payload.roomId, None)
        await get_stats_store().record_call_end(payload.roomId)

    async def ice_candidate(self, payload: IceCandidateRequest) -> None:
        await self._send_to(payload.targetUserId, {
            "type": "ice_candidate",
            "roomId": payload.roomId,
            "candidate": payload.candidate,
        })

    async def stats(self) -> Dict[str, Any]:
        async with self._lock:
            users = self._online_users_locked()
            return {
                "online_users": len(users),
                "users": users,
                "active_rooms": len(self._rooms),
            }

    async def _send_to(self, user_id: str, event: Dict[str, Any]) -> None:
        async with self._lock:
            websocket = self._websockets.get(user_id)
            queue = self._queue_for(user_id)

        if websocket:
            try:
                await websocket.send_json(event)
                return
            except Exception:
                async with self._lock:
                    if self._websockets.get(user_id) is websocket:
                        self._websockets.pop(user_id, None)

        await queue.put(event)

    async def _broadcast_user_list(self, users: List[str]) -> None:
        for user_id in users:
            await self._send_to(user_id, {"type": "user_list", "users": users})

    def _queue_for(self, user_id: str) -> asyncio.Queue:
        if user_id not in self._queues:
            self._queues[user_id] = asyncio.Queue()
        return self._queues[user_id]

    def _touch(self, user_id: str) -> None:
        self._last_seen[user_id] = time.monotonic()

    def _is_online_locked(self, user_id: str) -> bool:
        self._expire_stale_locked()
        return user_id in self._last_seen

    def _online_users_locked(self) -> List[str]:
        self._expire_stale_locked()
        return sorted(self._last_seen.keys())

    def _expire_stale_locked(self) -> None:
        now = time.monotonic()
        stale = [
            user_id
            for user_id, last_seen in self._last_seen.items()
            if now - last_seen > 60
        ]
        for user_id in stale:
            self._last_seen.pop(user_id, None)
            self._websockets.pop(user_id, None)


hub = SignalingHub()


@router.websocket("/ws/{user_id}")
async def websocket_signaling(websocket: WebSocket, user_id: str):
    await websocket.accept()
    await hub.register_websocket(user_id, websocket)
    try:
        while True:
            data = await websocket.receive_json()
            event_type = data.get("type")
            if event_type == "call_user":
                await hub.call_user(CallUserRequest(**data))
            elif event_type == "answer_call":
                await hub.answer_call(AnswerCallRequest(**data))
            elif event_type == "reject_call":
                await hub.reject_call(RejectCallRequest(**data))
            elif event_type == "end_call":
                await hub.end_call(EndCallRequest(**data))
            elif event_type == "ice_candidate":
                await hub.ice_candidate(IceCandidateRequest(**data))
    except WebSocketDisconnect:
        await hub.unregister(user_id, websocket)
    except Exception:
        await hub.unregister(user_id, websocket)


@router.post("/register")
async def register(payload: RegisterRequest):
    return await hub.register_http(payload.userId)


@router.post("/disconnect/{user_id}")
async def disconnect(user_id: str):
    await hub.unregister(user_id)
    return {"status": "ok"}


@router.get("/events/{user_id}")
async def events(user_id: str, timeout: int = 20):
    return await hub.events(user_id, timeout)


@router.post("/call")
async def call_user(payload: CallUserRequest):
    await hub.call_user(payload)
    return {"status": "ok"}


@router.post("/answer")
async def answer_call(payload: AnswerCallRequest):
    await hub.answer_call(payload)
    return {"status": "ok"}


@router.post("/reject")
async def reject_call(payload: RejectCallRequest):
    await hub.reject_call(payload)
    return {"status": "ok"}


@router.post("/end")
async def end_call(payload: EndCallRequest):
    await hub.end_call(payload)
    return {"status": "ok"}


@router.post("/ice")
async def ice_candidate(payload: IceCandidateRequest):
    await hub.ice_candidate(payload)
    return {"status": "ok"}


@router.get("/stats")
async def stats():
    return await hub.stats()
