package app.firedancergui;
import java.nio.file.*; import org.json.JSONObject;
public class Edge { public static void main(String[] a) throws Exception {
  StringBuilder o = new StringBuilder();
  for (String l : Files.readAllLines(Paths.get(a[0]))) { if (l.isEmpty()) continue; JSONObject j = new JSONObject(l); byte[] b = Pack.pack(j.getJSONObject("m"));
    StringBuilder h = new StringBuilder(); for (byte x : b) h.append(String.format("%02x", x)); j.put("hex", h.toString()); o.append(j).append('\n'); }
  Files.write(Paths.get(a[1]), o.toString().getBytes("UTF-8")); } }
