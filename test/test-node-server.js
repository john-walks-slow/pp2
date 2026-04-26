// Simple Node.js HTTP server for testing
const http = require('http');
const PORT = 19981;

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('PP2 Node.js Test OK\n');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Node.js HTTP server running on port ${PORT}`);
});