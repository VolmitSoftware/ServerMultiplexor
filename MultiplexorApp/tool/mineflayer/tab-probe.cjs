const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'TabProbe', auth: 'offline' });
let done = false;
const finish = (code) => { if (done) return; done = true; try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(code), 400); };
bot.once('spawn', () => {
  console.log('SPAWNED ' + bot.username);
  setTimeout(() => {
    try {
      const tl = bot.tablist || {};
      const plain = (c) => { if (!c) return '(none)'; if (typeof c === 'string') return c;
        return (typeof c.toString === 'function' ? c.toString() : JSON.stringify(c)); };
      console.log('HEADER: ' + plain(tl.header));
      console.log('FOOTER: ' + plain(tl.footer));
      const names = Object.keys(bot.players || {});
      console.log('TABLIST ENTRIES: ' + names.length);
      for (const n of names) {
        const p = bot.players[n];
        let dn = p && p.displayName ? p.displayName.toString() : '(no displayName)';
        console.log('  ' + n + ' -> ' + dn);
      }
    } catch (e) { console.log('PROBE ERROR: ' + e.message); }
    finish(0);
  }, 6000);
});
bot.on('error', (e) => { console.log('ERROR: ' + e.message); finish(1); });
bot.on('kicked', (r) => { console.log('KICKED: ' + JSON.stringify(r).slice(0,200)); finish(1); });
setTimeout(() => { console.log('TIMEOUT'); finish(1); }, 60000);
