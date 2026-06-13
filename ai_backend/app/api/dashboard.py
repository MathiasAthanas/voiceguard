import asyncio
import json
import os
import secrets
from typing import Set

from fastapi import APIRouter, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse
from pydantic import BaseModel

import app.database as db
from app.api.signaling import hub
from app.stats_store import get_stats_store

router = APIRouter()

# ── auth ──────────────────────────────────────────────────────────────────────

_PIN: str = os.getenv("DASHBOARD_PIN", "")
_valid_tokens: Set[str] = set()


def _auth_enabled() -> bool:
    return bool(_PIN)


def _check_token(token: str) -> bool:
    if not _auth_enabled():
        return True
    return token in _valid_tokens


class PinRequest(BaseModel):
    pin: str


@router.post("/auth")
async def authenticate(payload: PinRequest):
    if not _auth_enabled():
        return {"ok": True, "token": "open", "requires_pin": False}
    if payload.pin != _PIN:
        raise HTTPException(status_code=401, detail="Invalid PIN")
    token = secrets.token_hex(20)
    _valid_tokens.add(token)
    return {"ok": True, "token": token, "requires_pin": True}


@router.get("/ping")
async def ping(token: str = ""):
    if not _check_token(token):
        raise HTTPException(status_code=401, detail="Unauthorized")
    return {"ok": True, "requires_pin": _auth_enabled()}


# ── history (for charts) ──────────────────────────────────────────────────────

@router.get("/history")
async def history(token: str = ""):
    if not _check_token(token):
        raise HTTPException(status_code=401, detail="Unauthorized")
    loop = asyncio.get_running_loop()
    data = await loop.run_in_executor(None, db.get_chart_data, 24, 7)
    return data


# ── SSE stream ────────────────────────────────────────────────────────────────

@router.get("/stream")
async def dashboard_stream(token: str = ""):
    if not _check_token(token):
        raise HTTPException(status_code=401, detail="Unauthorized")

    store = get_stats_store()

    async def generator():
        q = store.subscribe()
        try:
            while True:
                hub_stats = await hub.stats()
                data = store.snapshot(hub_stats)
                yield f"data: {json.dumps(data)}\n\n"
                try:
                    await asyncio.wait_for(q.get(), timeout=5.0)
                except asyncio.TimeoutError:
                    pass
        finally:
            store.unsubscribe(q)

    return StreamingResponse(
        generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


# ── HTML page ─────────────────────────────────────────────────────────────────

_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VoiceGuard — Dashboard</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0d1117;
  --surface:#161b22;
  --surface2:#21262d;
  --surface3:#2d333b;
  --border:#30363d;
  --border-subtle:#21262d;
  --blue:#388bfd;
  --blue-sub:rgba(56,139,253,0.12);
  --green:#3fb950;
  --green-sub:rgba(63,185,80,0.12);
  --red:#f85149;
  --red-sub:rgba(248,81,73,0.12);
  --amber:#d29922;
  --amber-sub:rgba(210,153,34,0.12);
  --purple:#bc8cff;
  --purple-sub:rgba(188,140,255,0.12);
  --text:#e6edf3;
  --text-secondary:#8b949e;
  --text-tertiary:#484f58;
}
body{background:var(--bg);color:var(--text);font-family:'Inter',system-ui,sans-serif;min-height:100vh;font-size:13px;line-height:1.5;-webkit-font-smoothing:antialiased}

/* ── LOGIN ─────────────────────────────────────────────────────── */
#login-overlay{
  position:fixed;inset:0;z-index:200;
  background:var(--bg);
  display:flex;align-items:center;justify-content:center;
}
.login-card{
  background:var(--surface);border:1px solid var(--border);
  border-radius:12px;padding:40px 36px;width:360px;text-align:center;
  box-shadow:0 16px 48px rgba(0,0,0,0.5);
}
.login-icon{
  width:48px;height:48px;border-radius:10px;margin:0 auto 22px;
  background:var(--blue-sub);border:1px solid rgba(56,139,253,0.25);
  display:flex;align-items:center;justify-content:center;
}
.login-icon svg{color:var(--blue)}
.login-title{font-size:18px;font-weight:700;letter-spacing:-0.3px;margin-bottom:5px}
.login-sub{font-size:13px;color:var(--text-secondary);margin-bottom:28px}
.pin-input{
  width:100%;background:var(--surface2);border:1px solid var(--border);
  border-radius:8px;padding:11px 16px;font-size:20px;letter-spacing:10px;
  color:var(--text);font-family:'Inter',monospace;text-align:center;
  outline:none;margin-bottom:12px;transition:border-color .15s;
}
.pin-input:focus{border-color:var(--blue);box-shadow:0 0 0 3px rgba(56,139,253,0.15)}
.pin-btn{
  width:100%;background:var(--blue);
  border:none;border-radius:8px;padding:11px;
  font-size:13px;font-weight:600;color:#fff;cursor:pointer;font-family:'Inter',sans-serif;
  transition:filter .15s,transform .1s;
}
.pin-btn:hover{filter:brightness(1.1)}
.pin-btn:active{transform:scale(.99)}
.pin-error{color:var(--red);font-size:12px;margin-top:10px;min-height:16px}

/* ── HEADER ──────────────────────────────────────────────────────── */
header{
  background:var(--surface);border-bottom:1px solid var(--border);
  height:56px;padding:0 28px;
  display:flex;align-items:center;justify-content:space-between;
  position:sticky;top:0;z-index:100;
}
.logo{display:flex;align-items:center;gap:9px;font-size:15px;font-weight:700;letter-spacing:-0.3px;color:var(--text)}
.logo-icon{
  width:30px;height:30px;border-radius:7px;
  background:var(--blue-sub);border:1px solid rgba(56,139,253,0.2);
  display:flex;align-items:center;justify-content:center;color:var(--blue);
}
.header-right{display:flex;align-items:center;gap:20px}
.live-badge{
  display:flex;align-items:center;gap:6px;
  font-size:11px;font-weight:600;color:var(--green);letter-spacing:.5px;
}
.live-dot{
  width:6px;height:6px;border-radius:50%;background:var(--green);
  box-shadow:0 0 0 0 rgba(63,185,80,0.4);
  animation:pulse-ring 1.8s ease-in-out infinite;
}
@keyframes pulse-ring{
  0%{box-shadow:0 0 0 0 rgba(63,185,80,0.4)}
  70%{box-shadow:0 0 0 6px rgba(63,185,80,0)}
  100%{box-shadow:0 0 0 0 rgba(63,185,80,0)}
}
.conn-indicator{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--text-secondary)}
.conn-dot{width:6px;height:6px;border-radius:50%;background:var(--green);flex-shrink:0}
.conn-dot.off{background:var(--red)}

/* ── LAYOUT ──────────────────────────────────────────────────────── */
main{padding:24px 28px;max-width:1440px;margin:0 auto}

/* ── STAT CARDS ──────────────────────────────────────────────────── */
.stat-row{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:16px}
@media(max-width:900px){.stat-row{grid-template-columns:repeat(2,1fr)}}
@media(max-width:500px){.stat-row{grid-template-columns:1fr}}
.stat{
  background:var(--surface);border:1px solid var(--border);
  border-radius:10px;padding:18px 20px;
  display:flex;align-items:center;gap:16px;
  transition:border-color .15s;cursor:default;
}
.stat:hover{border-color:var(--border-subtle);border-color:#3d444d}
.stat-icon-wrap{
  width:40px;height:40px;border-radius:8px;flex-shrink:0;
  display:flex;align-items:center;justify-content:center;
}
.stat.blue .stat-icon-wrap{background:var(--blue-sub);color:var(--blue)}
.stat.green .stat-icon-wrap{background:var(--green-sub);color:var(--green)}
.stat.red .stat-icon-wrap{background:var(--red-sub);color:var(--red)}
.stat.amber .stat-icon-wrap{background:var(--amber-sub);color:var(--amber)}
.stat-body{min-width:0}
.stat-label{font-size:11px;font-weight:500;color:var(--text-secondary);margin-bottom:4px;white-space:nowrap}
.stat-num{font-size:28px;font-weight:700;line-height:1;letter-spacing:-1px;color:var(--text);transition:color .2s}
.stat-sub{font-size:11px;color:var(--text-tertiary);margin-top:3px;white-space:nowrap}

/* ── GRID ──────────────────────────────────────────────────────── */
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px}
@media(max-width:800px){.grid2{grid-template-columns:1fr}}

/* ── PANEL ──────────────────────────────────────────────────────── */
.panel{background:var(--surface);border:1px solid var(--border);border-radius:10px;overflow:hidden}
.panel-head{
  display:flex;align-items:center;justify-content:space-between;
  padding:13px 18px;border-bottom:1px solid var(--border);
}
.panel-title{
  font-size:12px;font-weight:600;color:var(--text-secondary);
  display:flex;align-items:center;gap:7px;text-transform:uppercase;letter-spacing:.5px;
}
.panel-title svg{color:var(--text-tertiary);flex-shrink:0}
.count-badge{
  background:var(--surface2);border:1px solid var(--border);
  border-radius:20px;padding:1px 8px;font-size:11px;font-weight:600;color:var(--text-secondary);
}
.panel-body{padding:10px;max-height:300px;overflow-y:auto}
.panel-body.tall{max-height:380px}
.panel-body::-webkit-scrollbar{width:3px}
.panel-body::-webkit-scrollbar-thumb{background:var(--surface3);border-radius:3px}

/* ── CHARTS ──────────────────────────────────────────────────────── */
.chart-wrap{padding:16px 18px;height:200px;position:relative}

/* ── USERS ──────────────────────────────────────────────────────── */
.user-wrap{display:flex;flex-wrap:wrap;gap:6px;padding:12px 14px}
.user-chip{
  display:flex;align-items:center;gap:6px;
  background:var(--surface2);border:1px solid var(--border);
  border-radius:6px;padding:5px 10px 5px 7px;
  font-size:12px;font-weight:500;color:var(--text);
  animation:fadeIn .2s ease;
}
.user-avatar{
  width:20px;height:20px;border-radius:50%;flex-shrink:0;
  background:linear-gradient(135deg,#388bfd,#bc8cff);
  display:flex;align-items:center;justify-content:center;
  font-size:9px;font-weight:700;text-transform:uppercase;color:#fff;
}
.status-dot{width:5px;height:5px;border-radius:50%;background:var(--green);flex-shrink:0}

/* ── CALLS ──────────────────────────────────────────────────────── */
.call-row{
  display:flex;align-items:center;gap:11px;
  padding:10px 12px;border-radius:7px;margin-bottom:6px;
  background:var(--surface2);border:1px solid var(--border);
  animation:fadeIn .2s ease;
}
.call-row-icon{
  width:32px;height:32px;border-radius:50%;flex-shrink:0;
  background:var(--green-sub);border:1px solid rgba(63,185,80,0.2);
  display:flex;align-items:center;justify-content:center;color:var(--green);
}
.call-row-info{flex:1;min-width:0}
.call-row-names{font-size:12px;font-weight:600;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.call-row-dur{font-size:11px;color:var(--text-secondary);margin-top:1px}
.call-live-badge{
  font-size:10px;font-weight:600;color:var(--green);letter-spacing:.5px;
  background:var(--green-sub);border:1px solid rgba(63,185,80,0.2);
  border-radius:4px;padding:2px 7px;flex-shrink:0;text-transform:uppercase;
}

/* ── VERDICT BARS ──────────────────────────────────────────────── */
.bars-wrap{padding:14px 18px}
.bar-row{display:flex;align-items:center;gap:10px;margin-bottom:10px}
.bar-label-text{font-size:11px;color:var(--text-secondary);width:108px;flex-shrink:0;font-weight:500}
.bar-track{flex:1;height:6px;background:var(--surface3);border-radius:3px;overflow:hidden}
.bar-fill{height:100%;border-radius:3px;transition:width .5s ease}
.bar-fill.spoof_detected{background:#f85149}
.bar-fill.spoof_suspected{background:#d29922}
.bar-fill.verified_high,.bar-fill.verified{background:#3fb950}
.bar-fill.not_verified{background:#d29922}
.bar-fill.uncertain{background:#d29922;opacity:.7}
.bar-fill.silent{background:#484f58}
.bar-count-num{font-size:11px;font-weight:600;color:var(--text-secondary);width:22px;text-align:right;flex-shrink:0}

/* ── FEED ──────────────────────────────────────────────────────── */
.feed-row{
  display:flex;align-items:center;gap:10px;
  padding:8px 12px;border-radius:6px;margin-bottom:4px;
  border-left:2px solid transparent;
  animation:fadeIn .2s ease;
}
.feed-row:hover{background:var(--surface2)}
.feed-row.spoof_detected{border-left-color:var(--red)}
.feed-row.spoof_suspected{border-left-color:var(--amber)}
.feed-row.verified_high,.feed-row.verified{border-left-color:var(--green)}
.feed-row.not_verified{border-left-color:var(--amber)}
.feed-row.uncertain{border-left-color:#484f58}
.feed-row.silent{border-left-color:var(--surface3)}
.feed-row.enrolled{border-left-color:var(--blue)}

.feed-status{
  width:24px;height:24px;border-radius:50%;flex-shrink:0;
  display:flex;align-items:center;justify-content:center;
}
.feed-status.spoof_detected{background:var(--red-sub);color:var(--red)}
.feed-status.spoof_suspected{background:var(--amber-sub);color:var(--amber)}
.feed-status.verified_high,.feed-status.verified{background:var(--green-sub);color:var(--green)}
.feed-status.not_verified{background:var(--amber-sub);color:var(--amber)}
.feed-status.uncertain,.feed-status.silent{background:var(--surface3);color:var(--text-secondary)}
.feed-status.enrolled{background:var(--blue-sub);color:var(--blue)}

.feed-main{flex:1;min-width:0;display:flex;align-items:center;gap:8px}
.feed-contact{font-size:12px;font-weight:600;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0;flex-shrink:1}
.feed-verdict{
  font-size:10px;font-weight:600;letter-spacing:.3px;
  border-radius:4px;padding:2px 7px;white-space:nowrap;flex-shrink:0;
}
.feed-verdict.spoof_detected{background:var(--red-sub);color:var(--red)}
.feed-verdict.spoof_suspected{background:var(--amber-sub);color:var(--amber)}
.feed-verdict.verified_high,.feed-verdict.verified{background:var(--green-sub);color:var(--green)}
.feed-verdict.not_verified{background:var(--amber-sub);color:var(--amber)}
.feed-verdict.uncertain,.feed-verdict.silent{background:var(--surface3);color:var(--text-secondary)}
.feed-verdict.enrolled{background:var(--blue-sub);color:var(--blue)}
.feed-scores{display:flex;gap:4px;flex-shrink:0}
.feed-score{font-size:10px;color:var(--text-tertiary);background:var(--surface2);border:1px solid var(--border);border-radius:4px;padding:1px 6px}
.feed-time{font-size:10px;color:var(--text-tertiary);white-space:nowrap;flex-shrink:0;margin-left:auto}

/* ── EMPTY STATE ──────────────────────────────────────────────── */
.empty-state{
  text-align:center;padding:32px 20px;
  color:var(--text-tertiary);
}
.empty-state svg{margin-bottom:10px;opacity:.4}
.empty-state p{font-size:12px}

/* ── SPOOF ALERT NOTIFICATION ─────────────────────────────────── */
@keyframes slideDown{from{opacity:0;transform:translateX(-50%) translateY(-16px)}to{opacity:1;transform:translateX(-50%) translateY(0)}}
@keyframes fadeOut{from{opacity:1}to{opacity:0}}
.spoof-alert-toast{
  position:fixed;top:68px;left:50%;transform:translateX(-50%);z-index:9999;
  background:var(--surface);border:1px solid rgba(248,81,73,0.4);border-left:3px solid var(--red);
  border-radius:8px;padding:12px 18px;min-width:300px;max-width:420px;
  display:flex;align-items:flex-start;gap:12px;
  box-shadow:0 8px 24px rgba(0,0,0,0.4);
  animation:slideDown .25s ease, fadeOut .3s 4s forwards;
  pointer-events:none;
}
.spoof-alert-icon{color:var(--red);flex-shrink:0;margin-top:1px}
.spoof-alert-body{min-width:0}
.spoof-alert-title{font-size:13px;font-weight:600;color:var(--text);margin-bottom:2px}
.spoof-alert-sub{font-size:11px;color:var(--text-secondary)}

/* ── STAT CARD ALERT STATE ────────────────────────────────────── */
@keyframes card-alert{0%,100%{border-color:var(--border)}50%{border-color:rgba(248,81,73,0.5)}}
.stat.alerting{animation:card-alert .45s ease 4}

/* ── CONNECTION TOAST ─────────────────────────────────────────── */
#conn-toast{
  position:fixed;bottom:20px;right:20px;z-index:999;
  background:var(--surface);border:1px solid var(--border);
  border-radius:8px;padding:10px 14px;font-size:12px;color:var(--text-secondary);
  display:none;align-items:center;gap:8px;box-shadow:0 4px 16px rgba(0,0,0,0.4);
}
#conn-toast.show{display:flex}

@keyframes fadeIn{from{opacity:0;transform:translateY(-3px)}to{opacity:1;transform:translateY(0)}}
</style>
</head>
<body>

<!-- Login overlay -->
<div id="login-overlay" style="display:none">
  <div class="login-card">
    <div class="login-icon">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
    </div>
    <div class="login-title">VoiceGuard</div>
    <div class="login-sub">Enter your PIN to access the dashboard</div>
    <input class="pin-input" id="pin-input" type="password" maxlength="12"
           placeholder="• • • •" autocomplete="off"
           onkeydown="if(event.key==='Enter')submitPin()">
    <button class="pin-btn" onclick="submitPin()">Continue</button>
    <div class="pin-error" id="pin-error"></div>
  </div>
</div>

<!-- Header -->
<header>
  <div class="logo">
    <div class="logo-icon">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
    </div>
    VoiceGuard
  </div>
  <div class="header-right">
    <div class="conn-indicator">
      <div class="conn-dot" id="conn-dot"></div>
      <span id="conn-label">Connecting</span>
    </div>
    <div class="live-badge">
      <div class="live-dot"></div>
      Live
    </div>
  </div>
</header>

<main>

  <!-- Stat cards -->
  <div class="stat-row">
    <div class="stat blue">
      <div class="stat-icon-wrap">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>
      </div>
      <div class="stat-body">
        <div class="stat-label">Users Online</div>
        <div class="stat-num" id="s-online">—</div>
        <div class="stat-sub">Currently connected</div>
      </div>
    </div>
    <div class="stat green">
      <div class="stat-icon-wrap">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07A19.5 19.5 0 0 1 4.69 13a19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 3.6 2h3a2 2 0 0 1 2 1.72c.127.96.361 1.903.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.907.339 1.85.573 2.81.7A2 2 0 0 1 22 16.92z"/></svg>
      </div>
      <div class="stat-body">
        <div class="stat-label">Active Calls</div>
        <div class="stat-num" id="s-calls">—</div>
        <div class="stat-sub">In progress now</div>
      </div>
    </div>
    <div class="stat red" id="stat-spoofs-card">
      <div class="stat-icon-wrap">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
      </div>
      <div class="stat-body">
        <div class="stat-label">Spoofs Detected</div>
        <div class="stat-num" id="s-spoofs">—</div>
        <div class="stat-sub">Total since launch</div>
      </div>
    </div>
    <div class="stat amber">
      <div class="stat-icon-wrap">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>
      </div>
      <div class="stat-body">
        <div class="stat-label">Verifications Run</div>
        <div class="stat-num" id="s-verifs">—</div>
        <div class="stat-sub" id="s-verifs-sub">Authenticated sessions</div>
      </div>
    </div>
  </div>

  <!-- Online users + Active calls -->
  <div class="grid2">
    <div class="panel">
      <div class="panel-head">
        <div class="panel-title">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="2"/><path d="M16.24 7.76a6 6 0 0 1 0 8.49m-8.48-.01a6 6 0 0 1 0-8.49m11.31-2.82a10 10 0 0 1 0 14.14m-14.14 0a10 10 0 0 1 0-14.14"/></svg>
          Online Users
        </div>
        <span class="count-badge" id="b-users">0</span>
      </div>
      <div class="user-wrap" id="users-list">
        <div class="empty-state" style="width:100%">
          <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/></svg>
          <p>No users connected</p>
        </div>
      </div>
    </div>
    <div class="panel">
      <div class="panel-head">
        <div class="panel-title">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07A19.5 19.5 0 0 1 4.69 13a19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 3.6 2h3a2 2 0 0 1 2 1.72c.127.96.361 1.903.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.907.339 1.85.573 2.81.7A2 2 0 0 1 22 16.92z"/></svg>
          Active Calls
        </div>
        <span class="count-badge" id="b-calls">0</span>
      </div>
      <div class="panel-body" id="calls-list">
        <div class="empty-state">
          <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07A19.5 19.5 0 0 1 4.69 13a19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 3.6 2h3a2 2 0 0 1 2 1.72c.127.96.361 1.903.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.907.339 1.85.573 2.81.7A2 2 0 0 1 22 16.92z"/></svg>
          <p>No active calls</p>
        </div>
      </div>
    </div>
  </div>

  <!-- Charts -->
  <div class="grid2">
    <div class="panel">
      <div class="panel-head">
        <div class="panel-title">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/></svg>
          Verifications — Last 24h
        </div>
      </div>
      <div class="chart-wrap"><canvas id="chart-verifs"></canvas></div>
    </div>
    <div class="panel">
      <div class="panel-head">
        <div class="panel-title">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg>
          Calls — Last 7 Days
        </div>
      </div>
      <div class="chart-wrap"><canvas id="chart-calls"></canvas></div>
    </div>
  </div>

  <!-- Verdict breakdown + Enrollments -->
  <div class="grid2">
    <div class="panel">
      <div class="panel-head">
        <div class="panel-title">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="3" y1="15" x2="21" y2="15"/><line x1="9" y1="3" x2="9" y2="21"/><line x1="15" y1="3" x2="15" y2="21"/></svg>
          Verdict Breakdown
        </div>
        <span class="count-badge" id="b-verifs-total">0 total</span>
      </div>
      <div class="bars-wrap" id="bars">
        <div class="empty-state"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg><p>No data yet</p></div>
      </div>
    </div>
    <div class="panel">
      <div class="panel-head">
        <div class="panel-title">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" y1="19" x2="12" y2="23"/><line x1="8" y1="23" x2="16" y2="23"/></svg>
          Recent Enrollments
        </div>
        <span class="count-badge" id="b-enrolls">0</span>
      </div>
      <div class="panel-body" id="enroll-list">
        <div class="empty-state"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/></svg><p>No enrollments yet</p></div>
      </div>
    </div>
  </div>

  <!-- Live verification feed -->
  <div class="panel">
    <div class="panel-head">
      <div class="panel-title">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>
        Verification Feed
      </div>
      <span class="count-badge" id="b-feed">0 events</span>
    </div>
    <div class="panel-body tall" id="feed-list">
      <div class="empty-state">
        <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>
        <p>Waiting for verification events</p>
      </div>
    </div>
  </div>

</main>

<div id="conn-toast">
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
  Connection lost — reconnecting
</div>

<script>
// ── SVG icons for feed status indicators ──────────────────────────────
const ICO = {
  spoof:    `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>`,
  verified: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>`,
  rejected: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>`,
  uncertain:`<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>`,
  mic:      `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/></svg>`,
};

const VERDICT_ICON = {
  spoof_detected: ICO.spoof,
  spoof_suspected: ICO.spoof,
  verified_high:  ICO.verified,
  verified:       ICO.verified,
  not_verified:   ICO.rejected,
  uncertain:      ICO.uncertain,
  silent:         ICO.uncertain,
  enrolled:       ICO.mic,
};

const VERDICT_LABEL = {
  spoof_detected: 'Spoof',
  spoof_suspected: 'Spoof Suspected',
  verified_high:  'Verified',
  verified:       'Verified',
  not_verified:   'Not Verified',
  uncertain:      'Uncertain',
  silent:         'Silent',
};

const VERDICT_CSS = {
  spoof_detected: 'spoof_detected',
  spoof_suspected: 'spoof_suspected',
  verified_high:  'verified_high',
  verified:       'verified',
  not_verified:   'not_verified',
  uncertain:      'uncertain',
  silent:         'silent',
};

// ── helpers ────────────────────────────────────────────────────────────
const $=id=>document.getElementById(id);
const fmtTime=ts=>new Date(ts*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit',second:'2-digit'});
const fmtDur=s=>{const m=Math.floor(s/60),r=s%60;return m>0?`${m}m ${r}s`:`${r}s`};
const initials=n=>n.split(/[\s_-]+/).map(w=>w[0]||'').join('').toUpperCase().slice(0,2)||'?';
const pct=(n,t)=>t?Math.round(n/t*100):0;

// ── auth ───────────────────────────────────────────────────────────────
let TOKEN = localStorage.getItem('vg_token') || '';

async function submitPin() {
  const pin = $('pin-input').value;
  $('pin-error').textContent = '';
  try {
    const r = await fetch('/dashboard/auth', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({pin}),
    });
    if (!r.ok) { $('pin-error').textContent = 'Incorrect PIN. Please try again.'; return; }
    const data = await r.json();
    TOKEN = data.token;
    localStorage.setItem('vg_token', TOKEN);
    $('login-overlay').style.display = 'none';
    startDashboard();
  } catch(e) {
    $('pin-error').textContent = 'Unable to reach server.';
  }
}

async function checkAuth() {
  try {
    const r = await fetch(`/dashboard/ping?token=${TOKEN}`);
    if (r.ok) { $('login-overlay').style.display = 'none'; startDashboard(); }
    else { $('login-overlay').style.display = 'flex'; setTimeout(()=>$('pin-input').focus(), 80); }
  } catch(e) { setTimeout(checkAuth, 2000); }
}

// ── spoof alert ────────────────────────────────────────────────────────
let prevSpoofs = null;
if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
  Notification.requestPermission();
}

function triggerSpoofAlert() {
  // 1. Slide-in notification
  const el = document.createElement('div');
  el.className = 'spoof-alert-toast';
  el.innerHTML = `
    <div class="spoof-alert-icon">${ICO.spoof.replace('width="12" height="12"','width="16" height="16"')}</div>
    <div class="spoof-alert-body">
      <div class="spoof-alert-title">Spoofed Voice Detected</div>
      <div class="spoof-alert-sub">An AI-generated or cloned voice was identified</div>
    </div>`;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 4500);

  // 2. Border highlight on spoof stat card
  const card = $('stat-spoofs-card');
  card.classList.add('alerting');
  setTimeout(() => card.classList.remove('alerting'), 1800);

  // 3. Audio alert
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    [[0, 800, 0.28], [0.2, 800, 0.28], [0.4, 1000, 0.22]].forEach(([when, freq, vol]) => {
      const osc = ctx.createOscillator(), gain = ctx.createGain();
      osc.connect(gain); gain.connect(ctx.destination);
      osc.type = 'sine'; osc.frequency.value = freq;
      gain.gain.setValueAtTime(vol, ctx.currentTime + when);
      gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + when + 0.13);
      osc.start(ctx.currentTime + when); osc.stop(ctx.currentTime + when + 0.13);
    });
  } catch(_) {}

  // 4. Browser notification
  if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
    new Notification('VoiceGuard — Spoof Alert', {
      body: 'An AI-generated or cloned voice was detected during verification.',
      tag: 'vg-spoof',
    });
  }
}

// ── charts ─────────────────────────────────────────────────────────────
const CHART_BASE = {
  responsive: true,
  maintainAspectRatio: false,
  animation: { duration: 300 },
  plugins: {
    legend: {
      labels: { color: '#6e7681', font: { size: 11, family: 'Inter' }, boxWidth: 10, padding: 14 }
    },
  },
  scales: {
    x: {
      ticks: { color: '#484f58', font: { size: 10, family: 'Inter' }, maxTicksLimit: 8 },
      grid: { color: 'rgba(255,255,255,0.03)' },
    },
    y: {
      ticks: { color: '#484f58', font: { size: 10, family: 'Inter' } },
      grid: { color: 'rgba(255,255,255,0.03)' },
      beginAtZero: true,
    },
  },
};

let chartVerifs = null, chartCalls = null;

function initCharts() {
  chartVerifs = new Chart($('chart-verifs'), {
    type: 'line',
    data: {
      labels: [],
      datasets: [
        {
          label: 'Verifications', data: [],
          borderColor: '#388bfd', backgroundColor: 'rgba(56,139,253,0.06)',
          tension: 0.35, fill: true, pointRadius: 2, pointHoverRadius: 4,
          borderWidth: 1.5,
        },
        {
          label: 'Spoofs', data: [],
          borderColor: '#f85149', backgroundColor: 'rgba(248,81,73,0.06)',
          tension: 0.35, fill: true, pointRadius: 2, pointHoverRadius: 4,
          borderWidth: 1.5,
        },
      ],
    },
    options: CHART_BASE,
  });

  chartCalls = new Chart($('chart-calls'), {
    type: 'bar',
    data: {
      labels: [],
      datasets: [{
        label: 'Calls', data: [],
        backgroundColor: 'rgba(188,140,255,0.4)',
        borderColor: '#bc8cff',
        borderWidth: 1,
        borderRadius: 3,
      }],
    },
    options: CHART_BASE,
  });
}

async function refreshCharts() {
  try {
    const r = await fetch(`/dashboard/history?token=${TOKEN}`);
    if (!r.ok) return;
    const d = await r.json();
    if (chartVerifs) {
      chartVerifs.data.labels = d.hourly.labels;
      chartVerifs.data.datasets[0].data = d.hourly.verifications;
      chartVerifs.data.datasets[1].data = d.hourly.spoofs;
      chartVerifs.update();
    }
    if (chartCalls) {
      chartCalls.data.labels = d.daily_calls.labels;
      chartCalls.data.datasets[0].data = d.daily_calls.counts;
      chartCalls.update();
    }
  } catch(_) {}
}

// ── render ─────────────────────────────────────────────────────────────
function render(d) {
  if (prevSpoofs !== null && d.total_spoofs > prevSpoofs) triggerSpoofAlert();
  prevSpoofs = d.total_spoofs;

  // Stat numbers
  $('s-online').textContent = d.online_users ?? 0;
  $('s-calls').textContent = d.active_calls ?? 0;
  $('s-spoofs').textContent = d.total_spoofs ?? 0;
  $('s-verifs').textContent = d.total_verifications ?? 0;
  $('s-verifs-sub').textContent = `${d.total_verified ?? 0} authenticated`;

  // Online users
  const users = d.users || [];
  $('b-users').textContent = users.length;
  $('users-list').innerHTML = users.length
    ? users.map(u => `
        <div class="user-chip">
          <div class="user-avatar">${initials(u)}</div>
          ${u}
          <div class="status-dot"></div>
        </div>`).join('')
    : `<div class="empty-state" style="width:100%">
         <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/></svg>
         <p>No users connected</p>
       </div>`;

  // Active calls
  const calls = d.active_call_list || [];
  $('b-calls').textContent = calls.length;
  $('calls-list').innerHTML = calls.length
    ? calls.map(c => `
        <div class="call-row">
          <div class="call-row-icon">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07A19.5 19.5 0 0 1 4.69 13a19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 3.6 2h3a2 2 0 0 1 2 1.72c.127.96.361 1.903.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.907.339 1.85.573 2.81.7A2 2 0 0 1 22 16.92z"/></svg>
          </div>
          <div class="call-row-info">
            <div class="call-row-names">${c.caller} &rarr; ${c.callee}</div>
            <div class="call-row-dur" data-start="${c.duration}">${fmtDur(c.duration)}</div>
          </div>
          <div class="call-live-badge">Live</div>
        </div>`).join('')
    : `<div class="empty-state">
         <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07A19.5 19.5 0 0 1 4.69 13a19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 3.6 2h3a2 2 0 0 1 2 1.72c.127.96.361 1.903.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.907.339 1.85.573 2.81.7A2 2 0 0 1 22 16.92z"/></svg>
         <p>No active calls</p>
       </div>`;

  // Verdict breakdown bars
  const verifs = d.recent_verifications || [];
  $('b-verifs-total').textContent = `${d.total_verifications ?? 0} total`;
  if (!verifs.length) {
    $('bars').innerHTML = `<div class="empty-state"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg><p>No data yet</p></div>`;
  } else {
    const counts = {};
    verifs.forEach(v => { counts[v.verdict] = (counts[v.verdict] || 0) + 1; });
    const total = verifs.length;
    const order = ['spoof_detected','spoof_suspected','verified_high','verified','not_verified','uncertain','silent'];
    const labels = {spoof_detected:'Spoof Detected',spoof_suspected:'Spoof Suspected',verified_high:'Verified (High)',verified:'Verified',not_verified:'Not Verified',uncertain:'Uncertain',silent:'Silent'};
    $('bars').innerHTML = order.filter(v => counts[v]).map(v => `
      <div class="bar-row">
        <div class="bar-label-text">${labels[v]||v}</div>
        <div class="bar-track"><div class="bar-fill ${v}" style="width:${pct(counts[v],total)}%"></div></div>
        <div class="bar-count-num">${counts[v]}</div>
      </div>`).join('');
  }

  // Enrollments
  const enrolls = d.recent_enrollments || [];
  $('b-enrolls').textContent = d.total_enrollments ?? 0;
  $('enroll-list').innerHTML = enrolls.length
    ? enrolls.map(e => `
        <div class="feed-row enrolled">
          <div class="feed-status enrolled">${ICO.mic}</div>
          <div class="feed-main">
            <span class="feed-contact">${e.contact_id}</span>
            <span class="feed-verdict enrolled">Enrolled</span>
          </div>
          <div class="feed-time">${fmtTime(e.timestamp)}</div>
        </div>`).join('')
    : `<div class="empty-state"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/></svg><p>No enrollments yet</p></div>`;

  // Verification feed
  $('b-feed').textContent = `${d.total_verifications ?? 0} events`;
  $('feed-list').innerHTML = verifs.length
    ? verifs.map(v => {
        const cls = VERDICT_CSS[v.verdict] || 'uncertain';
        const scores = [];
        if (v.spoof_probability > 0.01) scores.push(`Spoof ${(v.spoof_probability*100).toFixed(0)}%`);
        if (v.similarity_score != null) scores.push(`Match ${(v.similarity_score*100).toFixed(0)}%`);
        return `
          <div class="feed-row ${cls}">
            <div class="feed-status ${cls}">${VERDICT_ICON[v.verdict]||ICO.uncertain}</div>
            <div class="feed-main">
              <span class="feed-contact">${v.contact_id}</span>
              <span class="feed-verdict ${cls}">${VERDICT_LABEL[v.verdict]||v.verdict}</span>
              <div class="feed-scores">${scores.map(s=>`<span class="feed-score">${s}</span>`).join('')}</div>
            </div>
            <div class="feed-time">${fmtTime(v.timestamp)}</div>
          </div>`;
      }).join('')
    : `<div class="empty-state"><svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg><p>Waiting for verification events</p></div>`;
}

// Call duration ticker
setInterval(() => {
  document.querySelectorAll('.call-row-dur').forEach(el => {
    const s = parseInt(el.dataset.start || 0, 10) + 1;
    el.dataset.start = s; el.textContent = fmtDur(s);
  });
}, 1000);

setInterval(refreshCharts, 60000);

// ── SSE ────────────────────────────────────────────────────────────────
let es = null, retryTimer = null;

function setConn(ok) {
  $('conn-dot').className = 'conn-dot' + (ok ? '' : ' off');
  $('conn-label').textContent = ok ? 'Connected' : 'Reconnecting';
  ok ? $('conn-toast').classList.remove('show') : $('conn-toast').classList.add('show');
}

function connect() {
  if (es) { es.close(); es = null; }
  es = new EventSource(`/dashboard/stream?token=${TOKEN}`);
  es.onopen = () => setConn(true);
  es.onmessage = e => { try { render(JSON.parse(e.data)); } catch(_) {} };
  es.onerror = () => {
    es.close(); es = null; setConn(false);
    clearTimeout(retryTimer); retryTimer = setTimeout(connect, 3000);
  };
}

function startDashboard() { initCharts(); connect(); refreshCharts(); }

checkAuth();
</script>
</body>
</html>"""


@router.get("/", response_class=HTMLResponse)
async def dashboard_page():
    return HTMLResponse(content=_HTML)
