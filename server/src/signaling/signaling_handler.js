/**
 * Signaling handler — Socket.io event wiring.
 *
 * Local-network mode (no FCM).
 * If the callee is offline, the caller gets an immediate call_failed.
 * Both phones must have the app open for VoIP to work.
 */

const { v4: uuidv4 } = require('uuid');
const roomManager = require('./room_manager');
const logger = require('../utils/logger');

function handleSignaling(io, socket) {

  // ── Register ──────────────────────────────────────────────────────────────
  socket.on('register', ({ userId }) => {
    if (!userId) return;

    roomManager.registerUser(userId, socket.id);
    socket.userId = userId;

    logger.info(`User registered: ${userId} → socket ${socket.id}`);

    socket.emit('registered', { userId, socketId: socket.id });
    io.emit('user_list', { users: roomManager.getAllUsers() });
  });

  // ── Initiate a call ───────────────────────────────────────────────────────
  socket.on('call_user', ({ calleeId, offer, callerId }) => {
    const calleeSocket = roomManager.getUserSocket(calleeId);

    if (!calleeSocket) {
      socket.emit('call_failed', { reason: `${calleeId} is offline or not connected` });
      return;
    }

    const roomId = uuidv4();
    roomManager.createRoom(roomId, callerId, calleeId);

    logger.info(`Call: ${callerId} → ${calleeId} | Room: ${roomId}`);

    io.to(calleeSocket).emit('incoming_call', { callerId, roomId, offer });
    socket.emit('call_created', { roomId });
  });

  // ── Answer ────────────────────────────────────────────────────────────────
  socket.on('answer_call', ({ roomId, answer, callerId }) => {
    const callerSocket = roomManager.getUserSocket(callerId);
    if (!callerSocket) {
      socket.emit('call_failed', { reason: 'Caller disconnected' });
      return;
    }
    logger.info(`Call answered | Room: ${roomId}`);
    io.to(callerSocket).emit('call_answered', { roomId, answer });
  });

  // ── Reject ────────────────────────────────────────────────────────────────
  socket.on('reject_call', ({ roomId, callerId }) => {
    const callerSocket = roomManager.getUserSocket(callerId);
    if (callerSocket) io.to(callerSocket).emit('call_rejected', { roomId });
    roomManager.deleteRoom(roomId);
    logger.info(`Call rejected | Room: ${roomId}`);
  });

  // ── ICE candidates ────────────────────────────────────────────────────────
  socket.on('ice_candidate', ({ roomId, candidate, targetUserId }) => {
    const targetSocket = roomManager.getUserSocket(targetUserId);
    if (targetSocket) {
      io.to(targetSocket).emit('ice_candidate', { roomId, candidate });
    }
  });

  // ── Audio relay ───────────────────────────────────────────────────────────
  socket.on('audio_chunk', ({ roomId, senderUserId, data }) => {
    const room = roomManager.getRoom(roomId);
    if (!room) return;
    // Prefer socket-level userId; fall back to explicit payload field so
    // routing works regardless of how the client connected.
    const myUserId = socket.userId || roomManager.getUserBySocket(socket.id) || senderUserId;
    const targetUserId = room.caller === myUserId ? room.callee : room.caller;
    const targetSocket = roomManager.getUserSocket(targetUserId);
    if (targetSocket) {
      io.to(targetSocket).emit('audio_chunk', { roomId, data });
    }
  });

  // ── End call ──────────────────────────────────────────────────────────────
  socket.on('end_call', ({ roomId, targetUserId }) => {
    const targetSocket = roomManager.getUserSocket(targetUserId);
    if (targetSocket) io.to(targetSocket).emit('call_ended', { roomId });
    roomManager.deleteRoom(roomId);
    logger.info(`Call ended | Room: ${roomId}`);
  });

  // ── Disconnect ────────────────────────────────────────────────────────────
  socket.on('disconnect', () => {
    const userId = roomManager.unregisterSocket(socket.id);
    if (userId) {
      io.emit('user_list', { users: roomManager.getAllUsers() });
      logger.info(`User disconnected: ${userId}`);
    }
  });
}

module.exports = { handleSignaling };
