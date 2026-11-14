package app.firedancergui;
import java.io.*; import java.nio.charset.StandardCharsets; import java.security.MessageDigest; import java.util.*; import java.util.concurrent.*;
/** A badge console that misbehaves like a busy badge: log lines after the prompt, a lost line end. */
public class FakeBadge implements Installer.Port {
  Installer ins; final boolean noisy; StringBuilder rx = new StringBuilder(); int lines = 0, dropped = 0;
  final Map<String, ByteArrayOutputStream> parts = new HashMap<>(); final Map<String, byte[]> stored = new HashMap<>();
  final ScheduledExecutorService ex = Executors.newSingleThreadScheduledExecutor();
  FakeBadge(boolean noisy) { this.noisy = noisy; }
  void emit(String s) { byte[] b = s.getBytes(StandardCharsets.ISO_8859_1); ex.schedule(() -> ins.received(b, b.length), 3, TimeUnit.MILLISECONDS); }
  public synchronized void write(byte[] b) {
    for (byte x : b) { char ch = (char) (x & 0xff);
      if (ch == '\n') continue;
      if (ch == '\r') { if (noisy && rx.indexOf(" end") >= 0 && dropped < 1) { dropped++; continue; } String l = rx.toString(); rx.setLength(0); run(l); }
      else { rx.append(ch); emit(String.valueOf(ch)); } } }
  void run(String line) {
    lines++; String[] a = line.trim().split("\\s+"); String o = "";
    try {
      if (line.trim().isEmpty()) o = "";
      else if (a[0].equals("info")) o = "Solana OS 2.1.0 (esp32c5)\r\n";
      else if (a[0].equals("open")) o = "";
      else if (a[0].equals("lua") && a[1].equals("put")) {
        String k = a[3];
        if (a[4].equals("begin")) parts.put(k, new ByteArrayOutputStream());
        else if (a[4].equals("end")) { stored.put(k, parts.get(k).toByteArray()); o = a[2] + "/" + k + ": " + stored.get(k).length + " bytes\r\n"; }
        else parts.get(k).write(Base64.getDecoder().decode(a[4]));
      } else if (a[0].equals("lua") && a[1].equals("sums")) {
        for (Map.Entry<String, byte[]> e : stored.entrySet()) { StringBuilder h = new StringBuilder(); for (byte x : MessageDigest.getInstance("SHA-256").digest(e.getValue())) h.append(String.format("%02x", x)); o += h + " " + e.getValue().length + " " + e.getKey() + "\r\n"; }
        o += "sums: " + stored.size() + " files\r\n";
      } else if (a[0].equals("lua") && a[1].equals("run")) o = "";
      else o = "Unrecognized command\r\n";
    } catch (Exception e) { o = "error " + e + "\r\n"; }
    emit("\r\n" + o + "sol> ");
    if (noisy && lines % 7 == 3) ex.schedule(() -> { byte[] b = ("\r\nI (" + lines + ") cloud: hello ok\r\n").getBytes(); ins.received(b, b.length); }, 20, TimeUnit.MILLISECONDS);
  }
  public static void main(String[] args) throws Exception {
    FakeBadge f = new FakeBadge(args[1].equals("noisy"));
    Installer ins = new Installer(f, new Installer.Log() {
      public void line(String s, int kind) { System.out.println((kind == 1 ? "[ok] " : kind == 2 ? "[err] " : "") + s); }
      public void progress(double p) {} });
    f.ins = ins;
    long t0 = System.currentTimeMillis();
    ins.run(args[0]);
    byte[] want = java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(args[2]));
    System.out.println("main.lua on fake badge identical: " + Arrays.equals(f.stored.get("main.lua"), want) + " | lines: " + f.lines + " | lost line ends: " + f.dropped + " | seconds: " + (System.currentTimeMillis() - t0) / 1000.0);
    f.ex.shutdownNow();
  }
}
