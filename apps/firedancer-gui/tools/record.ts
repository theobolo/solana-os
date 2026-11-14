const ws = new WebSocket(process.argv[3] ?? 'ws://localhost:8080/live'); const t0 = Date.now(); const out: string[] = [];
ws.onmessage = (e) => out.push(JSON.stringify({ at: Date.now() - t0, m: JSON.parse(e.data as string) }));
setTimeout(async () => { await Bun.write(process.argv[2], out.join('\n')); process.exit(0); }, 45000);
