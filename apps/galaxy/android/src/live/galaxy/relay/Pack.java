package live.galaxy.relay;

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

    private static boolean truthy(Object o) {
        if (o instanceof Boolean) return (Boolean) o;
        if (o instanceof Number) { double d = ((Number) o).doubleValue(); return d != 0 && !Double.isNaN(d); }
        if (o instanceof String) return !((String) o).isEmpty();
        return o != null && o != JSONObject.NULL;
    }

    static byte[] pack(JSONObject m) {
        String t = m.optString("t");
        if (t.equals("f")) {
            JSONArray r = m.optJSONArray("r");
            if (r == null || r.length() != 5) return null;
            ByteBuffer b = ByteBuffer.allocate(184).order(ByteOrder.LITTLE_ENDIAN);
            b.put(0, (byte) 'F');
            b.putInt(1, (int) m.optLong("e"));
            b.putShort(5, (short) cap(m.optDouble("ok", 0), 65535));
            b.putShort(7, (short) cap(m.optDouble("fail", 0), 65535));
            for (int j = 0; j < 5; j++) {
                JSONArray w = r.optJSONArray(j);
                if (w == null) return null;
                int o = 9 + j * 35;
                b.put(o, (byte) (truthy(w.opt(2)) ? 1 : 0));
                String cells = w.optString(3, "");
                int c = 0;
                for (int n = 0; n < 4; n++) {
                    int d = n < cells.length() ? Character.digit(cells.charAt(n), 10) : 0;
                    c |= (Math.max(d, 0) & 15) << (n * 4);
                }
                b.putShort(o + 1, (short) c);
                JSONArray per = w.optJSONArray(5);
                for (int n = 0; n < 8; n++) b.putShort(o + 3 + n * 2, (short) cap(per == null ? 0 : per.optDouble(n, 0), 65535));
                b.putInt(o + 19, cap(w.optDouble(6, 0), 2147483647L));    // fees, lamports
                b.putShort(o + 23, (short) cap(w.optDouble(7, 0), 65535)); // ms per slot
                String name = w.optString(1, "").replaceAll("[^\\x20-\\x7e]", "");
                if (name.length() > 10) name = name.substring(0, 10);
                for (int n = 0; n < name.length(); n++) b.put(o + 25 + n, (byte) name.charAt(n));
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
            ByteBuffer b = ByteBuffer.allocate(26 + nn * 4 + nl * 2).order(ByteOrder.LITTLE_ENDIAN);
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
            for (int n = 0; n < nn; n++) b.putInt(26 + n * 4, (int) next.optLong(n));
            for (int n = 0; n < nl; n++) {
                JSONArray x = last.optJSONArray(n);
                int v = x == null ? 0 : cap(x.optDouble(0, 0), 32767) | (truthy(x.opt(1)) ? 0x8000 : 0);
                b.putShort(26 + nn * 4 + n * 2, (short) v);
            }
            return b.array();
        }
        return null;
    }
}
