package app.firedancergui;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.json.JSONArray;
import org.json.JSONObject;

/** A relay message (JSON, see core.ts) packed for one Bluetooth write, or null. The same
 *  bytes as packMsg() in worker/src/install.html; the badge app (main.lua, unpackMsg) reads them. */
final class Pack {
    private Pack() {}

    private static int cap(double v, long max) {
        if (Double.isNaN(v) || Double.isInfinite(v)) v = 0;
        long r = Math.round(v);
        if (r < 0) r = 0;
        if (r > max) r = max;
        return (int) r;
    }

    private static void text(ByteBuffer b, String v, int o, int max) {
        String t = v.replaceAll("[^\\x20-\\x7e]", "");
        if (t.length() > max) t = t.substring(0, max);
        for (int n = 0; n < t.length(); n++) b.put(o + n, (byte) t.charAt(n));
    }

    private static boolean truthy(Object o) {
        if (o instanceof Boolean) return (Boolean) o;
        if (o instanceof Number) { double d = ((Number) o).doubleValue(); return d != 0 && !Double.isNaN(d); }
        if (o instanceof String) return !((String) o).isEmpty();
        return o != null && o != JSONObject.NULL;
    }

    static byte[] pack(JSONObject m) {
        String t = m.optString("t");
        if (t.equals("f")) {
            ByteBuffer b = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN);
            b.put(0, (byte) 'F');
            b.putInt(1, (int) Math.max(0, Math.min(4294967295L, Math.round(m.optDouble("e", 0)))));
            b.putShort(5, (short) cap(m.optDouble("ok", 0), 65535));
            b.putShort(7, (short) cap(m.optDouble("fail", 0), 65535));
            return b.array();
        }
        if (t.equals("w")) {
            JSONArray d = m.optJSONArray("d");
            if (d == null || d.length() != 4) return null;
            ByteBuffer b = ByteBuffer.allocate(92).order(ByteOrder.LITTLE_ENDIAN);
            b.put(0, (byte) 'W');
            b.putInt(1, (int) m.optLong("s"));
            b.put(5, (byte) (truthy(m.opt("o")) ? 1 : 0));
            b.putInt(6, cap(m.optDouble("k", 0), 2147483647L));
            String cc = m.optString("c", "").replaceAll("[^A-Z]", "");
            if (cc.length() > 2) cc = cc.substring(0, 2);
            while (cc.length() < 2) cc += " ";
            b.put(10, (byte) cc.charAt(0));
            b.put(11, (byte) cc.charAt(1));
            String name = m.optString("n", "").replaceAll("[^\\x20-\\x7e]", "");
            if (name.length() > 16) name = name.substring(0, 16);
            for (int n = 0; n < name.length(); n++) b.put(12 + n, (byte) name.charAt(n));
            for (int j = 0; j < 4; j++) {               // state, tx, failed, fees, tips, ms, CU %
                JSONArray x = d.optJSONArray(j);
                int o = 28 + j * 16;
                b.put(o, (byte) cap(x == null ? 0 : x.optDouble(0, 0), 15));
                b.putShort(o + 1, (short) cap(x == null ? 0 : x.optDouble(1, 0), 65535));
                b.putShort(o + 3, (short) cap(x == null ? 0 : x.optDouble(2, 0), 65535));
                b.putInt(o + 5, cap(x == null ? 0 : x.optDouble(3, 0), 2147483647L));
                b.putInt(o + 9, cap(x == null ? 0 : x.optDouble(4, 0), 2147483647L));
                b.putShort(o + 13, (short) cap(x == null ? 0 : x.optDouble(5, 0), 65535));
                b.put(o + 15, (byte) cap(x == null ? 0 : x.optDouble(6, 0), 255));
            }
            return b.array();
        }
        if (t.equals("slot")) {
            ByteBuffer b = ByteBuffer.allocate(13).order(ByteOrder.LITTLE_ENDIAN);
            b.put(0, (byte) 'S');
            b.putInt(1, (int) m.optLong("s"));
            b.put(5, (byte) (m.optInt("i") & 3));
            b.put(6, (byte) ("ok".equals(m.optString("st")) ? 1 : 0));
            b.putShort(7, (short) cap(m.optDouble("tx", 0), 65535));
            b.putInt(9, cap(m.optDouble("fee", 0), 2147483647L));
            return b.array();
        }
        if (t.equals("info")) {
            JSONArray next = m.optJSONArray("next"), last = m.optJSONArray("last");
            int nn = next == null ? 0 : Math.min(next.length(), 24), nl = last == null ? 0 : Math.min(last.length(), 16);
            ByteBuffer b = ByteBuffer.allocate(50 + nn * 4 + nl * 2).order(ByteOrder.LITTLE_ENDIAN);
            b.put(0, (byte) 'I');
            b.putInt(1, cap(m.optDouble("stake", 0), 2147483647L));
            b.putShort(5, (short) cap(m.optDouble("share", 0) * 1000, 65535));
            b.putShort(7, (short) cap(m.optDouble("rank", 0), 65535));
            b.putShort(9, (short) (!m.has("comm") || m.isNull("comm") ? 0xffff : cap(m.optDouble("comm", 0) * 100, 10000)));
            b.put(11, (byte) (truthy(m.opt("delinq")) ? 1 : 0));
            b.putShort(12, (short) cap(m.optDouble("epoch", 0), 65535));
            b.put(14, (byte) cap(m.optDouble("pct", 0), 100));
            b.putShort(15, (short) cap(m.optDouble("sd", 0), 65535));
            b.putShort(17, (short) cap(m.optDouble("leader", 0), 65535));
            b.putShort(19, (short) cap(m.optDouble("done", 0), 65535));
            b.putShort(21, (short) cap(m.optDouble("skip", 0), 65535));
            b.put(23, (byte) ("live".equals(m.optString("up")) ? 1 : 0));
            b.put(24, (byte) nn);
            b.put(25, (byte) nl);
            text(b, m.isNull("name") ? "" : m.optString("name", ""), 26, 16);   // the validator's name
            text(b, m.isNull("ver") ? "" : m.optString("ver", ""), 42, 8);      // the Firedancer version
            for (int n = 0; n < nn; n++) b.putInt(50 + n * 4, (int) next.optLong(n));
            for (int n = 0; n < nl; n++) {
                JSONArray x = last.optJSONArray(n);
                int v = x == null ? 0 : cap(x.optDouble(0, 0), 32767) | (truthy(x.opt(1)) ? 0x8000 : 0);
                b.putShort(50 + nn * 4 + n * 2, (short) v);
            }
            return b.array();
        }
        return null;
    }
}
