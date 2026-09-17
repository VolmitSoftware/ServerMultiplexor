const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'AegyronProbe', auth: 'offline' });
const say = m => console.log('[test] ' + m);
const inv = () => bot.inventory.items().map(i => i.name + 'x' + i.count).sort().join(',') || '(empty)';
const bail = (m, c) => { say(m); try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(c), 600); };
const wait = ms => new Promise(r => setTimeout(r, ms));
let spawns = 0, given = false, before = '';
bot.on('kicked', r => bail('KICKED: ' + JSON.stringify(r).slice(0, 300), 1));
bot.on('error', e => bail('ERROR: ' + e.message, 1));
bot.on('message', m => { const t = m.toString().trim();
  if (/home|claim|block|synchron|Teleport|permission|Unknown/i.test(t) && t.length < 160) say('chat| ' + t); });

bot.on('spawn', async () => {
  spawns++; await wait(4500);
  if (!given) {
    given = true;
    say('on ' + (spawns === 1 ? 'first server' : '?') + ', inventory: ' + inv());
    bot.chat('/give AegyronProbe diamond 7'); await wait(1800);
    bot.chat('/give AegyronProbe emerald 4'); await wait(2500);
    before = inv(); say('after give: ' + before);
    bot.chat('/sethome switchtest'); await wait(2000);
    bot.chat('/claim 5'); await wait(2500);
    bot.chat('/claimblocks'); await wait(2500);
    say('switching to aegyron-bot2'); bot.chat('/server aegyron-bot2'); return;
  }
  const after = inv(); say('after switch, inventory: ' + after);
  const ok = after.includes('diamondx7') && after.includes('emeraldx4');
  say('RESULT: ' + (ok ? 'ITEMS SURVIVED THE SWITCH' : 'MISMATCH before=[' + before + '] after=[' + after + ']'));
  bot.chat('/home switchtest'); await wait(2500);
  bot.chat('/trustlevels'); await wait(2000);
  bail('done', ok ? 0 : 1);
});
setTimeout(() => bail('TIMEOUT', 1), 95000);
