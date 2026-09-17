const mineflayer = require('mineflayer');
const port = parseInt(process.argv[2], 10);
const bot = mineflayer.createBot({ host: '127.0.0.1', port, username: 'DirectProbe', auth: 'offline' });
const wait = ms => new Promise(r => setTimeout(r, ms));
const bail = (m, c) => { console.log(m); try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(c), 500); };
bot.on('kicked', r => bail('KICKED: ' + JSON.stringify(r).slice(0, 200), 1));
bot.on('error', e => bail('ERROR ' + e.message, 1));
bot.on('message', m => { const t = m.toString().trim(); if (t && t.length < 180) console.log('   < ' + t); });
let ran = false;
bot.on('spawn', async () => { if (ran) return; ran = true; await wait(4000);
  for (const c of ['/husk status', '/husk version', '/husk reload']) { console.log('[cmd] ' + c); bot.chat(c); await wait(3000); }
  bail('[done]', 0); });
setTimeout(() => bail('TIMEOUT', 1), 60000);
