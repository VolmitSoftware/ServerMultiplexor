const mineflayer = require('mineflayer');
const version = process.argv[2];
const name = 'Proto' + version.replace(/\./g, '');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: name, version, auth: 'offline' });
let spawned = false, kicked = null;
const out = (m) => console.log('[' + version + '] ' + m);
bot.on('kicked', r => { kicked = JSON.stringify(r).slice(0, 220); });
bot.on('error', e => { if (!kicked) kicked = 'ERROR ' + e.message; });
bot.once('spawn', () => { spawned = true; out('spawned as ' + bot.username + ' (protocol ' + bot.protocolVersion + ')'); });
setTimeout(() => {
  if (!spawned) { out('RESULT: FAILED TO SPAWN - ' + (kicked || 'timeout')); process.exit(1); }
  out('username=' + name);
  setTimeout(() => {
    const entries = Object.keys(bot.players).length;
    const self = bot.players[bot.username];
    out('tab entries=' + entries + ' displayName=' + (self && self.displayName ? self.displayName.toString().slice(0, 50) : 'none'));
    out('RESULT: ' + (kicked ? 'KICKED AFTER TEAM PACKET - ' + kicked : 'SURVIVED'));
    try { bot.quit(); } catch (e) {}
    setTimeout(() => process.exit(kicked ? 1 : 0), 400);
  }, 12000);
}, 22000);
