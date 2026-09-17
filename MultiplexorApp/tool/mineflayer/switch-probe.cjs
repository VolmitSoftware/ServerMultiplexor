const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'SwitchProbe', auth: 'offline' });
const log = [];
let phase = 'before';
let done = false;
const finish = (c) => { if (done) return; done = true; try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(c), 400); };
const txt = (v) => { if (!v) return '(null)'; try { const j = JSON.stringify(v);
  const m = j.match(/"text":\{"type":"string","value":"([^"]*)"\}/); return m ? m[1] : j.slice(0,60); } catch (e) { return '?'; } };
bot._client.on('teams', (p) => {
  log.push(phase + ' | mode=' + p.mode + ' team=' + p.team + ' prefix=' + txt(p.prefix) + ' suffix=' + txt(p.suffix) + ' collision=' + p.collisionRule);
});
bot.once('spawn', () => {
  console.log('SPAWNED on first server');
  setTimeout(() => {
    phase = 'switching';
    console.log('--> /server aegyron-bot2');
    bot.chat('/server aegyron-bot2');
    setTimeout(() => {
      phase = 'after';
      setTimeout(() => {
        console.log('TEAM PACKET TIMELINE:');
        for (const l of log) console.log('  ' + l);
        finish(0);
      }, 8000);
    }, 4000);
  }, 6000);
});
bot.on('error', (e) => { console.log('ERROR: ' + e.message); finish(1); });
bot.on('kicked', (r) => { console.log('KICKED: ' + JSON.stringify(r).slice(0,150)); finish(1); });
setTimeout(() => { console.log('TIMEOUT'); for (const l of log) console.log('  ' + l); finish(1); }, 70000);
