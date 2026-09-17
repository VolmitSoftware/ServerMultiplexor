const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'AegyronProbe', auth: 'offline' });
const say = m => console.log('[bisect] ' + m);
const bail = (m, c) => { say(m); try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(c), 500); };
let spawns = 0;
bot.on('kicked', r => bail('KICKED: ' + JSON.stringify(r).slice(0, 200), 1));
bot.on('error', e => bail('ERROR: ' + e.message, 1));
bot.on('spawn', () => { spawns++;
  if (spawns === 1) { setTimeout(() => { say('switching'); bot.chat('/server aegyron-bot2'); }, 4000); }
  else { bail('SWITCH SUCCEEDED with no proxy plugins', 0); } });
setTimeout(() => bail('TIMEOUT', 1), 60000);
