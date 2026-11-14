import fs from 'fs';
const html = fs.readFileSync(process.argv[2], 'utf8');
const packMsg = new Function(html.match(/<script id="pack">([\s\S]*?)<\/script>/)[1] + '; return packMsg;')();
let same = 0, diff = 0; const kinds = {};
for (const l of fs.readFileSync(process.argv[3], 'utf8').split('\n').filter(Boolean)) {
  const { m, hex } = JSON.parse(l);
  const js = Buffer.from(packMsg(m)).toString('hex');
  kinds[m.t] = (kinds[m.t] || 0) + 1;
  if (js === hex) same++; else { diff++; if (diff < 3) console.log('DIFF', m.t, '\n js', js, '\n java', hex); }
}
console.log('Java vs page: identical', same, 'different', diff, kinds);
