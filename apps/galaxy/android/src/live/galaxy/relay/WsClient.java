package live.galaxy.relay;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Base64;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/** Just enough of a WebSocket client (RFC 6455) to read the relay's text messages:
 *  no extensions, answers pings, masks what it sends. */
final class WsClient {
    interface Listener { void onText(String text); }

    private final String host, path;
    private final int port;
    private final boolean tls;
    private Socket sock;
    private InputStream in;
    private OutputStream out;

    WsClient(String host, int port, boolean tls, String path) {
        this.host = host; this.port = port; this.tls = tls; this.path = path;
    }

    void connect() throws IOException {
        Socket s;
        if (tls) {
            SSLSocket ss = (SSLSocket) SSLSocketFactory.getDefault().createSocket(host, port);   // sets SNI
            ss.setSoTimeout(15000);
            ss.startHandshake();
            s = ss;
        } else {
            s = new Socket();
            s.connect(new InetSocketAddress(host, port), 15000);
        }
        s.setSoTimeout(15000);            // the relay talks ~10 times a second: 15 s of silence is a dead link
        s.setTcpNoDelay(true);
        sock = s;
        in = new BufferedInputStream(s.getInputStream());
        out = s.getOutputStream();
        byte[] key = new byte[16];
        new SecureRandom().nextBytes(key);
        String req = "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: " + Base64.getEncoder().encodeToString(key) + "\r\nSec-WebSocket-Version: 13\r\n"
                + "User-Agent: GalaxyLive-Android/1\r\n\r\n";
        out.write(req.getBytes(StandardCharsets.US_ASCII));
        out.flush();
        String status = line();
        if (!status.startsWith("HTTP/1.1 101")) throw new IOException("relay said " + status);
        while (!line().isEmpty()) { /* headers */ }
    }

    /** Reads messages until the connection ends (throws). */
    void run(Listener l) throws IOException {
        ByteArrayOutputStream frag = null;
        for (;;) {
            int b0 = byte1(), b1 = byte1();
            boolean fin = (b0 & 0x80) != 0, masked = (b1 & 0x80) != 0;
            int op = b0 & 0x0f;
            long len = b1 & 0x7f;
            if (len == 126) len = (byte1() << 8) | byte1();
            else if (len == 127) { len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | byte1(); }
            if (len > (1 << 20)) throw new IOException("message too big");
            byte[] mask = masked ? bytes(4) : null;
            byte[] p = bytes((int) len);
            if (mask != null) for (int i = 0; i < p.length; i++) p[i] ^= mask[i & 3];
            switch (op) {
                case 0: case 1: case 2:
                    if (op != 0) frag = new ByteArrayOutputStream();
                    if (frag == null) break;
                    frag.write(p, 0, p.length);
                    if (fin) { l.onText(new String(frag.toByteArray(), StandardCharsets.UTF_8)); frag = null; }
                    break;
                case 8: send(8, new byte[0]); throw new EOFException("relay closed");
                case 9: send(10, p); break;                 // ping: pong
                default: break;                            // pong, or something we don't use
            }
        }
    }

    void close() {
        try { if (sock != null) sock.close(); } catch (IOException ignored) {}
    }

    private synchronized void send(int op, byte[] p) throws IOException {
        ByteArrayOutputStream f = new ByteArrayOutputStream();
        f.write(0x80 | op);
        if (p.length < 126) f.write(0x80 | p.length);
        else { f.write(0x80 | 126); f.write(p.length >> 8); f.write(p.length & 0xff); }
        byte[] mask = new byte[4];
        new SecureRandom().nextBytes(mask);
        f.write(mask, 0, 4);
        for (int i = 0; i < p.length; i++) f.write(p[i] ^ mask[i & 3]);
        out.write(f.toByteArray());
        out.flush();
    }

    private int byte1() throws IOException {
        int b = in.read();
        if (b < 0) throw new EOFException("relay gone");
        return b;
    }

    private byte[] bytes(int n) throws IOException {
        byte[] b = new byte[n];
        for (int o = 0; o < n; ) {
            int r = in.read(b, o, n - o);
            if (r < 0) throw new EOFException("relay gone");
            o += r;
        }
        return b;
    }

    private String line() throws IOException {
        StringBuilder s = new StringBuilder();
        for (int c; (c = byte1()) != '\n'; ) if (c != '\r') s.append((char) c);
        return s.toString();
    }
}
