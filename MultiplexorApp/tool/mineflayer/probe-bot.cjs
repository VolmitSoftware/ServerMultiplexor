const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'AegyronProbe', auth: 'offline' });
let done = false;
const finish = (msg, code) => { if (done) return; done = true; console.log(msg); try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(code), 500); };
bot.once('spawn', () => finish('CONNECTED: ' + bot.username + ' version=' + bot.version, 0));
bot.on('error', (e) => finish('ERROR: ' + e.message, 1));
bot.on('kicked', (r) => finish('KICKED: ' + JSON.stringify(r).slice(0, 300), 1));
setTimeout(() => finish('TIMEOUT: no spawn in 45s', 1), 45000);
