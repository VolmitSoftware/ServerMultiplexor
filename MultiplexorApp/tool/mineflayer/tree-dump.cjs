const mineflayer = require('mineflayer');
const bot = mineflayer.createBot({ host: '127.0.0.1', port: 25565, username: 'AegyronProbe', auth: 'offline' });
const bail = (m, c) => { console.log(m); try { bot.quit(); } catch (e) {} setTimeout(() => process.exit(c), 400); };
bot._client.on('declare_commands', (p) => {
  const nodes = p.nodes;
  const root = nodes[p.rootIndex];
  const named = {};
  for (const idx of root.children) {
    const n = nodes[idx];
    if (n.extraNodeData && n.extraNodeData.name) named[n.extraNodeData.name] = { idx, children: n.children.length, flags: n.flags };
  }
  for (const label of ['husk', 'husksynceverything', 'hse', 'sethome', 'userdata', 'claimblocks']) {
    const e = named[label];
    if (!e) { console.log(label.padEnd(20) + 'NOT IN TREE'); continue; }
    const kids = nodes[e.idx].children.map(i => {
      const k = nodes[i];
      return (k.extraNodeData && k.extraNodeData.name) || ('type' + (k.flags & 0x03));
    });
    console.log(label.padEnd(20) + 'children=' + e.children + '  ' + JSON.stringify(kids).slice(0, 90));
  }
  bail('[tree dumped]', 0);
});
bot.on('error', e => bail('ERROR ' + e.message, 1));
setTimeout(() => bail('TIMEOUT', 1), 45000);
