const mineflayer = require('mineflayer');
const version = process.argv[2];
const name = 'Proto' + version.replace(/\./g, '');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: name, version, auth: 'offline' });
const out = m => console.log('[' + version + '] ' + m);
let spawned = false, kicked = null;
bot.on('kicked', r => { kicked = JSON.stringify(r).slice(0, 200); });
bot.on('error', e => { if (!kicked) kicked = 'ERROR ' + e.message; });
bot.once('spawn', () => { spawned = true; out('spawned protocol=' + bot.protocolVersion); console.log('READY:' + name); });
setTimeout(() => {
  if (!spawned) { out('RESULT: NO SPAWN - ' + (kicked || 'timeout')); process.exit(1); }
  const self = bot.players[bot.username];
  out('tab displayName=' + (self && self.displayName ? self.displayName.toString().slice(0, 55) : 'none'));
  out('RESULT: ' + (kicked ? 'KICKED - ' + kicked : 'SURVIVED the team packet'));
  try { bot.quit(); } catch (e) {}
  setTimeout(() => process.exit(kicked ? 1 : 0), 400);
}, 26000);
