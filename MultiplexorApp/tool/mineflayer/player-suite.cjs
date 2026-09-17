const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'AegyronProbe', auth: 'offline' });
const say = m => console.log(m);
const inv = () => bot.inventory.items().map(i => i.name + 'x' + i.count).sort().join(',') || '(empty)';
const wait = ms => new Promise(r => setTimeout(r, ms));
const bail = (m, c) => { say('[done] ' + m); try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(c), 600); };
bot.on('kicked', r => bail('KICKED: ' + JSON.stringify(r).slice(0, 200), 1));
bot.on('error', e => bail('ERROR: ' + e.message, 1));
bot.on('message', m => { const t = m.toString().trim(); if (t && t.length < 200) say('  < ' + t); });
let ran = false;
bot.on('spawn', async () => {
  if (ran) return; ran = true;
  await wait(4500);
  say('[inv on join] ' + inv());
  const cmds = [
    '/give AegyronProbe diamond 7', '/give AegyronProbe emerald 4',
    '/sethome base', '/homelist', '/home base',
    '/claim 3', '/claimblocks', '/trustlevels', '/claimlist',
    '/warplist', '/tprequests', '/back',
    '/userdata list AegyronProbe',
    '/inventory AegyronProbe',
    '/husk status'
  ];
  for (const c of cmds) { say('[cmd] ' + c); bot.chat(c); await wait(2600); }
  say('[inv at end] ' + inv());
  bail('suite finished', 0);
});
setTimeout(() => bail('TIMEOUT', 1), 150000);
