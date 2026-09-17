const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'AegyronProbe', auth: 'offline' });
bot.once('spawn', () => { console.log('SPAWNED as ' + bot.username + ' v' + bot.version); });
bot.on('error', (e) => console.log('ERROR: ' + e.message));
bot.on('kicked', (r) => console.log('KICKED: ' + JSON.stringify(r).slice(0, 200)));
bot.on('end', (r) => { console.log('END: ' + r); process.exit(0); });
setTimeout(() => { console.log('HOLD COMPLETE'); try { bot.quit(); } catch (e) {} process.exit(0); }, 180000);
