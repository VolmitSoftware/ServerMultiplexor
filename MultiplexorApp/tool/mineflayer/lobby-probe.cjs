const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'LobbyProbe', auth: 'offline' });
const msgs = [];
let done = false;
const finish = (c) => { if (done) return; done = true; try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(c), 400); };
bot.on('message', (m) => { const s = m.toString().trim(); if (s) msgs.push(s); });
const run = (cmd, wait) => new Promise(r => { console.log('>> ' + cmd); bot.chat(cmd); setTimeout(r, wait); });
bot.once('spawn', async () => {
  console.log('SPAWNED (entry server)');
  await new Promise(r => setTimeout(r, 4000));
  msgs.length = 0;
  // per-server command pointing at the server we are already on -> refusal
  await run('/qa', 2500);
  // cooldown check: immediately again
  await run('/qa', 2500);
  // shared command -> should route to the other backend
  await run('/lobby', 3500);
  console.log('--- RESPONSES ---');
  for (const m of msgs.slice(0, 14)) console.log('  ' + m);
  finish(0);
});
bot.on('error', (e) => { console.log('(bot error: ' + e.message + ')'); });
bot.on('kicked', (r) => {
  console.log('--- RESPONSES BEFORE KICK ---');
  for (const m of msgs.slice(0, 14)) console.log('  ' + m);
  console.log('KICKED (expected on switch: known mineflayer/Velocity 4.2 config-phase issue)');
  finish(0);
});
setTimeout(() => { for (const m of msgs.slice(0,14)) console.log('  ' + m); finish(1); }, 60000);
