package app.firedancergui;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Copies the badge app onto the badge through its serial console (`lua put`), then checks
 *  the card's SHA-256 sums and starts it. The same dialogue as the install page
 *  (worker/src/install.html). Plain Java: the port is whatever carries the bytes. */
final class Installer {
    interface Port { void write(byte[] b) throws IOException; }
    interface Log { void line(String s, int kind); void progress(double p); }   // kind: 0 info, 1 ok, 2 error

    static final String APP = "firedancer-gui";
    private static final Pattern ANSI = Pattern.compile("\u001b\\[[0-9;?]*[A-Za-z]");
    private static final Pattern NL_PROMPT = Pattern.compile("[\r\n][^\r\n]*sol>");

    private final Port port;
    private final Log log;
    private final StringBuilder buf = new StringBuilder();
    private volatile long lastRx;

    Installer(Port port, Log log) { this.port = port; this.log = log; }

    /** What the badge sent; call from the port's reading thread. */
    void received(byte[] b, int n) {
        synchronized (buf) { buf.append(new String(b, 0, n, StandardCharsets.ISO_8859_1)); }
        lastRx = now();
    }

    private static long now() { return System.nanoTime() / 1_000_000; }
    private static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); } }
    private String clean() { synchronized (buf) { return ANSI.matcher(buf).replaceAll(""); } }

    /** In small pieces: the badge reads its console between everything else it does. */
    private void send(String text) throws IOException {
        byte[] b = text.getBytes(StandardCharsets.ISO_8859_1);
        for (int o = 0; o < b.length; o += 32) {
            byte[] chunk = new byte[Math.min(32, b.length - o)];
            System.arraycopy(b, o, chunk, 0, chunk.length);
            port.write(chunk);
            sleep(4);
        }
    }

    static final class Failed extends IOException {
        final boolean fatal;
        Failed(String m, boolean fatal) { super(m); this.fatal = fatal; }
    }

    /** Sends a line and waits for the console's next prompt; returns what the command printed.
     *  The badge may print other lines after its prompt (logs), so the prompt is looked for
     *  after the echo of the line, not at the very end. `again`: safe to send twice. */
    String cmd(String line, long timeout, boolean again) throws IOException {
        String seen = "";
        for (int attempt = 0; attempt < (again ? 2 : 1); attempt++) {
            synchronized (buf) { buf.setLength(0); }
            send(line + "\r\n");
            String tail = line.length() > 12 ? line.substring(line.length() - 12) : line;
            long t0 = now();
            boolean nudged = false;
            for (;;) {
                sleep(12);
                String c = clean();
                long quiet = now() - lastRx;
                int i = tail.isEmpty() ? 0 : c.lastIndexOf(tail);
                if (i >= 0) {
                    String rest = c.substring(i + tail.length());
                    int j = rest.indexOf("sol>");
                    if (j >= 0 && (rest.substring(0, j).indexOf('\n') >= 0 || rest.substring(0, j).indexOf('\r') >= 0) && quiet > 30)
                        return rest.substring(0, j);
                }
                if (quiet > 500 && NL_PROMPT.matcher(c).find()) return c;   // the echo got mixed with other output
                long waited = now() - t0;
                if (!nudged && waited > timeout / 2) { nudged = true; send("\r\n"); }   // the line's end may have been lost
                if (waited > timeout) break;
            }
            seen = clean();
        }
        String last = seen.length() > 300 ? seen.substring(seen.length() - 300) : seen;
        throw new Failed("le badge ne répond pas à « " + (line.length() > 36 ? line.substring(0, 36) : line)
                + " » (console : " + last.replace("\r", "").replace("\n", " ⏎ ").trim() + ")", false);
    }

    private static String said(String out) {
        String s = out.replaceAll("\\s+", " ").trim();
        return s.length() > 160 ? s.substring(0, 160) : s;
    }

    private static byte[] fetch(String url) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(15000);
        try (InputStream in = c.getInputStream()) {
            if (c.getResponseCode() != 200) throw new IOException(url + " : HTTP " + c.getResponseCode());
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            byte[] b = new byte[8192];
            for (int n; (n = in.read(b)) > 0; ) o.write(b, 0, n);
            return o.toByteArray();
        } finally { c.disconnect(); }
    }

    private static String sha256(byte[] b) throws IOException {
        try {
            StringBuilder h = new StringBuilder();
            for (byte x : MessageDigest.getInstance("SHA-256").digest(b)) h.append(String.format("%02x", x & 0xff));
            return h.toString();
        } catch (Exception e) { throw new IOException(e); }
    }

    private void put(String name, byte[] bytes, int done, int total) throws IOException {
        String out = cmd("lua put " + APP + " " + name + " begin", 12000, true);
        if (Pattern.compile("no microSD|running|installing|usage|can't").matcher(out).find())
            throw new Failed(said(out), out.contains("no microSD"));
        for (int o = 0; o < bytes.length; o += 96) {
            int n = Math.min(96, bytes.length - o);
            byte[] part = new byte[n];
            System.arraycopy(bytes, o, part, 0, n);
            out = cmd("lua put " + APP + " " + name + " " + Base64.getEncoder().encodeToString(part), 12000, false);  // twice would write it twice
            if (Pattern.compile("bad base64|limited|write failed|first|usage|Unrecognized").matcher(out).find())
                throw new Failed(said(out), false);
            log.progress((done + o + n) / (double) total);
        }
        out = cmd("lua put " + APP + " " + name + " end", 12000, false);
        Matcher m = Pattern.compile(": (\\d+) bytes").matcher(out);
        if (!m.find() || Integer.parseInt(m.group(1)) != bytes.length) throw new Failed("taille reçue : " + said(out), false);
    }

    /** The whole installation; the app's files come from the relay (host). */
    void run(String host) throws IOException {
        log.line("Badge connecté, console…", 0);
        boolean up = false;
        for (int i = 0; i < 12 && !up; i++) {                 // the badge may be booting
            try { cmd("", 1500, false); up = true; } catch (IOException e) { /* again */ }
        }
        if (!up) throw new Failed("pas de console : le badge est-il allumé ?", true);
        Matcher v = Pattern.compile("(\\d+\\.\\d+\\.\\d+)").matcher(cmd("info", 12000, true));
        if (v.find()) log.line("Solana OS " + v.group(1), 0);
        cmd("open home", 12000, true);                       // close the app if it runs
        try { cmd("lua rm galaxy-live", 12000, true); } catch (IOException ignored) {}   // the app under its first name
        sleep(1500);                                          // let it close and the launcher draw

        String[] names = { "app.json", "main.lua" };
        byte[][] files = { fetch("https://" + host + "/app/app.json"), fetch("https://" + host + "/app/main.lua") };
        int total = files[0].length + files[1].length, done = 0;
        String[] sums = new String[2];
        for (int f = 0; f < 2; f++) {
            sums[f] = sha256(files[f]);
            for (int tries = 1; ; tries++) {
                try { put(names[f], files[f], done, total); break; }
                catch (Failed e) {
                    if (e.fatal || tries >= 3) throw e;
                    log.line(names[f] + " : nouvel essai (" + e.getMessage() + ")", 0);
                    try { cmd("", 3000, false); } catch (IOException ignored) {}
                }
            }
            done += files[f].length;
            log.line(names[f] + " : " + files[f].length + " octets", 1);
        }
        String check = cmd("lua sums " + APP, 12000, true).toLowerCase();   // what the card holds must be what we sent
        for (int f = 0; f < 2; f++) {
            if (!check.contains(sums[f] + " ")) throw new Failed(names[f] + " est arrivé abîmé sur le badge : relance l'installation", false);
        }
        log.line("Fichiers vérifiés (SHA-256)", 1);
        cmd("lua run " + APP, 12000, true);
        log.line("Installée et lancée sur le badge.", 1);
    }
}
