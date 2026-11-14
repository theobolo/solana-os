// Runs the installer page's USB code against a fake badge console that misbehaves the way
// a busy badge might: log lines after the prompt, and sometimes a lost end of line.
import fs from 'fs'; import crypto from 'crypto';
const root = process.argv[2], mode = process.argv[3] || 'noisy';
const html = fs.readFileSync(root + '/worker/src/install.html', 'utf8');
const script = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join('\n');
const logs = [];
const el = () => ({ hidden: true, append(e) { logs.push((e.className ? '[' + e.className + '] ' : '') + e.textContent); }, scrollTop: 0, scrollHeight: 0, value: 0, disabled: false });
const els = {};
globalThis.document = { getElementById: (id) => (els[id] ??= el()), createElement: () => ({}), addEventListener() {} };
globalThis.location = { hash: '', host: 'x' };
globalThis.fetch = async (u) => ({ text: async () => u.endsWith('main.lua') ? fs.readFileSync(root + '/main.lua', 'utf8') : JSON.stringify(JSON.parse(fs.readFileSync(root + '/app.json', 'utf8')), null, 2) + '\n' });
// the fake badge
const stored = {}, parts = {}; let rx = '', out = [], dropped = 0, lines = 0;
const emit = (s) => out.push(Buffer.from(s));
function run(line) {
  lines++;
  const a = line.trim().split(/\s+/);
  let o = '';
  if (line.trim() === '') o = '';
  else if (a[0] === 'info') o = 'Solana OS 2.1.0 (esp32c5)\r\n';
  else if (a[0] === 'open') o = '';
  else if (a[0] === 'lua' && a[1] === 'put') {
    const k = a[3];
    if (a[4] === 'begin') parts[k] = Buffer.alloc(0);
    else if (a[4] === 'end') { stored[k] = parts[k]; o = `${a[2]}/${k}: ${parts[k].length} bytes\r\n`; }
    else parts[k] = Buffer.concat([parts[k], Buffer.from(a[4], 'base64')]);
  } else if (a[0] === 'lua' && a[1] === 'sums') {
    for (const k in stored) o += `${crypto.createHash('sha256').update(stored[k]).digest('hex')} ${stored[k].length} ${k}\r\n`;
    o += `sums: ${Object.keys(stored).length} files\r\n`;
  } else if (a[0] === 'lua' && a[1] === 'run') o = '';
  else o = 'Unrecognized command\r\n';
  emit('\r\n' + o + 'sol> ');
  if (mode === 'noisy' && lines % 7 === 3) setTimeout(() => emit('\r\nI (' + lines + ') cloud: hello ok\r\n'), 20);   // a log line after the prompt
}
const dev = {
  configuration: { interfaces: [{ alternate: { endpoints: [{ direction: 'in', type: 'bulk', endpointNumber: 2 }, { direction: 'out', type: 'bulk', endpointNumber: 2 }] } }] },
  async open() {}, async claimInterface() {}, async close() {}, async controlTransferOut() {},
  async transferOut(ep, bytes) {
    for (const ch of Buffer.from(bytes).toString()) {
      if (ch === '\n') continue;
      if (ch === '\r') {
        if (mode === 'noisy' && rx.includes(' end') && dropped < 1) { dropped++; continue; }   // lose one end of line
        const l = rx; rx = ''; run(l);
      } else { rx += ch; emit(ch); }
    }
  },
  async transferIn() {
    await new Promise((r) => setTimeout(r, 3));
    if (!out.length) return { data: new DataView(new ArrayBuffer(0)) };
    const b = Buffer.concat(out.splice(0)); return { data: new DataView(b.buffer, b.byteOffset, b.byteLength) };
  },
};
Object.defineProperty(globalThis, 'navigator', { value: { usb: { requestDevice: async () => dev } }, configurable: true });
new Function(script)();
const t0 = Date.now();
await els.install.onclick();
console.log(logs.join('\n'));
const want = fs.readFileSync(root + '/main.lua');
console.log('main.lua on fake badge identical:', stored['main.lua']?.equals(want), '| lines:', lines, '| seconds:', ((Date.now() - t0) / 1000).toFixed(1), '| lost line ends:', dropped);
process.exit(0);
