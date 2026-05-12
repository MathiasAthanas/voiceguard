/**
 * RoomManager — in-memory state for the signaling server.
 *
 * Manages userId ↔ socketId mappings and active rooms.
 * Kept simple for local-network use (no FCM dependency).
 */

// Map<userId, socketId>
const userSocketMap = new Map();
// Map<socketId, userId>
const socketUserMap = new Map();
// Map<roomId, { caller, callee }>
const rooms = new Map();

// ── User registration ─────────────────────────────────────────────────────────

function registerUser(userId, socketId) {
  const oldSocketId = userSocketMap.get(userId);
  if (oldSocketId) socketUserMap.delete(oldSocketId);
  userSocketMap.set(userId, socketId);
  socketUserMap.set(socketId, userId);
}

function unregisterUser(userId) {
  const socketId = userSocketMap.get(userId);
  if (socketId) socketUserMap.delete(socketId);
  userSocketMap.delete(userId);
}

function unregisterSocket(socketId) {
  const userId = socketUserMap.get(socketId);
  if (!userId) return null;

  const currentSocketId = userSocketMap.get(userId);
  socketUserMap.delete(socketId);

  if (currentSocketId === socketId) {
    userSocketMap.delete(userId);
    return userId;
  }

  return null;
}

function getUserSocket(userId) {
  return userSocketMap.get(userId) || null;
}

function getUserBySocket(socketId) {
  return socketUserMap.get(socketId) || null;
}

function getAllUsers() {
  return Array.from(userSocketMap.keys());
}

// ── Rooms ─────────────────────────────────────────────────────────────────────

function createRoom(roomId, callerId, calleeId) {
  rooms.set(roomId, { caller: callerId, callee: calleeId });
}

function getRoom(roomId) {
  return rooms.get(roomId) || null;
}

function deleteRoom(roomId) {
  rooms.delete(roomId);
}

// ── Stats ─────────────────────────────────────────────────────────────────────

function getStats() {
  return {
    onlineUsers: userSocketMap.size,
    activeRooms: rooms.size,
  };
}

module.exports = {
  registerUser,
  unregisterUser,
  unregisterSocket,
  getUserSocket,
  getUserBySocket,
  getAllUsers,
  createRoom,
  getRoom,
  deleteRoom,
  getStats,
};
