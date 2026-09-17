const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'TeamProbe', auth: 'offline' });
const teams = [];
let done = false;
const finish = (c) => { if (done) return; done = true; try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(c), 400); };
// raw SetPlayerTeam packets - mineflayer's protocol layer parses these even though the API hides them
bot._client.on('teams', (p) => { teams.push(p); });
bot.once('spawn', () => {
  console.log('SPAWNED ' + bot.username + ' v' + bot.version);
  setTimeout(() => {
    console.log('TEAM PACKETS RECEIVED: ' + teams.length);
    for (const t of teams.slice(0, 4)) {
      console.log('  team=' + t.team + ' mode=' + t.mode);
      if (t.metadata) {
        const m = t.metadata;
        console.log('    prefix=' + JSON.stringify(m.prefix));
        console.log('    suffix=' + JSON.stringify(m.suffix));
        console.log('    color=' + m.color + ' collision=' + m.collisionRule + ' visibility=' + m.nameTagVisibility);
      }
      if (t.players) console.log('    players=' + JSON.stringify(t.players));
    }
    const me = bot.players[bot.username];
    console.log('DISPLAY NAME: ' + (me && me.displayName ? me.displayName.toString() : '(none)'));
    finish(0);
  }, 7000);
});
bot.on('error', (e) => { console.log('ERROR: ' + e.message); finish(1); });
bot.on('kicked', (r) => { console.log('KICKED: ' + JSON.stringify(r).slice(0,200)); finish(1); });
setTimeout(() => { console.log('TIMEOUT'); finish(1); }, 60000);
