const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'TeamProbe2', auth: 'offline' });
const teams = [];
let done = false;
const finish = (c) => { if (done) return; done = true; try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(c), 400); };
bot._client.on('teams', (p) => teams.push({ t: Date.now(), p }));
bot.once('spawn', () => {
  const t0 = Date.now();
  console.log('SPAWNED v' + bot.version);
  setTimeout(() => {
    console.log('TEAM PACKETS OVER 20s: ' + teams.length);
    for (const e of teams) {
      const p = e.p;
      const keys = Object.keys(p).join(',');
      console.log('  +' + (e.t - t0) + 'ms mode=' + p.mode + ' team=' + p.team + ' keys=[' + keys + ']');
      if (p.metadata) console.log('     metadata=' + JSON.stringify(p.metadata).slice(0, 300));
      if (p.players) console.log('     players=' + JSON.stringify(p.players));
    }
    finish(0);
  }, 20000);
});
bot.on('error', (e) => { console.log('ERROR: ' + e.message); finish(1); });
bot.on('kicked', (r) => { console.log('KICKED'); finish(1); });
setTimeout(() => { console.log('TIMEOUT'); finish(1); }, 70000);
