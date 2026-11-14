import fs from 'fs';
const html = fs.readFileSync(process.argv[2], 'utf8');
const src = html.match(/<script id="pack">([\s\S]*?)<\/script>/)[1];
const packMsg = new Function(src + '; return packMsg;')();
const lines = fs.readFileSync(process.argv[3], 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
let max = 0; const out = [];
for (const { at, m } of lines) { const b = packMsg(m); if (!b) throw new Error('unpacked ' + m.t); max = Math.max(max, b.length); out.push(at + ' ' + Buffer.from(b).toString('hex')); }
fs.writeFileSync(process.argv[4], out.join('\n'));
console.log('packed', out.length, 'messages, largest', max, 'bytes');
