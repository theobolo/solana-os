package live.galaxy.relay;

import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import java.io.IOException;

/** The badge's USB-serial chip (WCH CH340) through Android's USB host API: 115200 8N1,
 *  DTR and RTS off so the chip is neither held in reset nor in its bootloader. */
final class Ch340 implements Installer.Port {
    static final int VENDOR = 0x1a86;

    private final UsbDeviceConnection conn;
    private final UsbInterface iface;
    private final UsbEndpoint in, out;
    private volatile boolean open = true;
    private Thread reader;

    Ch340(UsbManager mgr, UsbDevice dev) throws IOException {
        conn = mgr.openDevice(dev);
        if (conn == null) throw new IOException("impossible d'ouvrir le port USB");
        iface = dev.getInterface(0);
        if (!conn.claimInterface(iface, true)) { conn.close(); throw new IOException("port USB occupé"); }
        UsbEndpoint i = null, o = null;
        for (int n = 0; n < iface.getEndpointCount(); n++) {
            UsbEndpoint e = iface.getEndpoint(n);
            if (e.getType() != UsbConstants.USB_ENDPOINT_XFER_BULK) continue;
            if (e.getDirection() == UsbConstants.USB_DIR_IN) i = e; else o = e;
        }
        if (i == null || o == null) { close(); throw new IOException("ce n'est pas un port série CH340"); }
        in = i;
        out = o;
        ctl(0xa1, 0, 0);            // serial init
        ctl(0x9a, 0x1312, 0xcc83);  // 115200 baud
        ctl(0x9a, 0x0f2c, 0x0008);
        ctl(0x9a, 0x2518, 0x00c3);  // 8N1, RX and TX on
        ctl(0xa4, 0xffff, 0);       // DTR and RTS off
    }

    private void ctl(int request, int value, int index) throws IOException {
        int r = conn.controlTransfer(UsbConstants.USB_TYPE_VENDOR | UsbConstants.USB_DIR_OUT, request, value, index, null, 0, 1000);
        if (r < 0) throw new IOException("réglage du port série refusé (" + Integer.toHexString(request) + ")");
    }

    /** Starts reading; everything that arrives goes to the installer. */
    void start(Installer ins) {
        reader = new Thread(() -> {
            byte[] b = new byte[256];
            while (open) {
                int n = conn.bulkTransfer(in, b, b.length, 200);
                if (n > 0) ins.received(b, n);
            }
        }, "ch340");
        reader.start();
    }

    @Override
    public void write(byte[] b) throws IOException {
        if (conn.bulkTransfer(out, b, b.length, 2000) != b.length) throw new IOException("écriture USB échouée");
    }

    void close() {
        open = false;
        try { if (reader != null) reader.join(500); } catch (InterruptedException ignored) {}
        try { conn.releaseInterface(iface); } catch (Exception ignored) {}
        conn.close();
    }
}
