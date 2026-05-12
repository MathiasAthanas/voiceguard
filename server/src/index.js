require('dotenv').config();
const os = require('os');
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const { handleSignaling } = require('./signaling/signaling_handler');
const logger = require('./utils/logger');

const app = express();
const server = http.createServer(app);

const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST'],
  },
  transports: ['websocket', 'polling'],
  pingInterval: 25000,
  pingTimeout: 60000,
  connectTimeout: 45000,
});

app.use(express.json());

const roomManager = require('./signaling/room_manager');

// Health / stats endpoint
app.get('/', (req, res) => {
  res.json({
    status: 'VoiceGuard Signaling Server Running',
    timestamp: new Date().toISOString(),
    ...roomManager.getStats(),
  });
});

// Socket.io signaling
io.on('connection', (socket) => {
  logger.info(`Client connected: ${socket.id} via ${socket.conn.transport.name}`);
  socket.conn.on('upgrade', (transport) => {
    logger.info(`Client upgraded: ${socket.id} via ${transport.name}`);
  });
  handleSignaling(io, socket);

  socket.on('disconnect', () => {
    logger.info(`Client disconnected: ${socket.id}`);
  });
});

const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || '0.0.0.0';

function getLanUrls(port) {
  const interfaces = os.networkInterfaces();
  const urls = [];

  for (const addresses of Object.values(interfaces)) {
    if (!addresses) continue;

    for (const address of addresses) {
      if (address.family !== 'IPv4' || address.internal) continue;
      urls.push(`http://${address.address}:${port}`);
    }
  }

  return urls;
}

server.listen(PORT, HOST, () => {
  logger.info(`Signaling server running at http://${HOST}:${PORT}`);
  const lanUrls = getLanUrls(PORT);
  if (lanUrls.length > 0) {
    logger.info('Available on your network:');
    lanUrls.forEach((url) => logger.info(`  ${url}`));
  }
  logger.info('Waiting for devices to connect on the same network...');
});
