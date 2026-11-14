package live.galaxy.relay;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothStatusCodes;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.ParcelUuid;
import android.os.PowerManager;
import android.os.SystemClock;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONException;
import org.json.JSONObject;

/** Follows the relay (GET /phone, a WebSocket) and writes what it says, packed, to the badge
 *  over Bluetooth (the Nordic UART service the badge app serves). A foreground service, so
 *  Android keeps it running while the phone does something else. */
public class RelayService extends Service {
    static final UUID NUS = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
    static final UUID RX = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e");
    private static final String CHANNEL = "relay";

    // What the screen shows (MainActivity reads these once a second)
    static volatile boolean running;
    static volatile String relayState = "arrêté", badgeState = "arrêté";
    static volatile int relayRate, badgeRate, mtu;

    private final AtomicInteger relayCount = new AtomicInteger(), badgeCount = new AtomicInteger();
    private volatile boolean stop;
    private HandlerThread bleThread;
    private Handler ble;                      // every Bluetooth call happens on this thread
    private PowerManager.WakeLock wake;
    private Thread wsThread;
    private volatile WsClient ws;

    // Bluetooth state (ble thread only)
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic rx;
    private boolean scanning, writing;
    private long writeAt;
    private ScanCallback scanCb;
    private int ticks;

    // What waits for the badge: our slots in order, then only the newest info and frame
    private final ArrayDeque<byte[]> slots = new ArrayDeque<>();
    private byte[] info, frame;

    @Override public IBinder onBind(Intent i) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (running) return START_STICKY;
        running = true;
        stop = false;
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Relais Galaxy Live", NotificationManager.IMPORTANCE_LOW));
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, note("Démarrage…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else startForeground(1, note("Démarrage…"));
        wake = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "galaxylive:relay");
        wake.acquire();
        bleThread = new HandlerThread("ble");
        bleThread.start();
        ble = new Handler(bleThread.getLooper());
        ble.post(this::scan);
        ble.postDelayed(this::tick, 1000);
        wsThread = new Thread(this::relayLoop, "relay");
        wsThread.start();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        stop = true;
        running = false;
        WsClient w = ws;
        if (w != null) w.close();
        if (ble != null) {
            ble.removeCallbacksAndMessages(null);
            ble.post(() -> {
                stopScan();
                if (gatt != null) { try { gatt.disconnect(); gatt.close(); } catch (SecurityException ignored) {} gatt = null; }
                bleThread.quitSafely();
            });
        }
        if (wake != null && wake.isHeld()) wake.release();
        relayState = "arrêté";
        badgeState = "arrêté";
        relayRate = badgeRate = 0;
        super.onDestroy();
    }

    private Notification note(String text) {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle("Galaxy Live")
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(true)
                .build();
    }

    // ------------------------------------------------------------------ the relay

    private void relayLoop() {
        int delay = 1000;
        while (!stop) {
            relayState = "connexion…";
            WsClient w = new WsClient(Config.HOST, 443, true, "/phone?k=" + Config.KEY);
            ws = w;
            try {
                w.connect();
                relayState = "connecté";
                delay = 1000;
                w.run(this::onMessage);
            } catch (Exception e) {
                if (!stop) relayState = "coupé (" + e.getMessage() + ")";
            } finally {
                w.close();
            }
            if (stop) break;
            SystemClock.sleep(delay);
            delay = Math.min(delay * 2, 15000);
        }
    }

    private void onMessage(String text) {
        relayCount.incrementAndGet();
        JSONObject m;
        try { m = new JSONObject(text); } catch (JSONException e) { return; }
        byte[] b = Pack.pack(m);
        if (b == null) return;
        String t = m.optString("t");
        synchronized (this) {
            if (t.equals("slot")) { slots.add(b); while (slots.size() > 32) slots.poll(); }
            else if (t.equals("info")) info = b;
            else frame = b;
        }
        ble.post(this::pump);
    }

    // ------------------------------------------------------------------ the badge

    private void scan() {
        if (stop || gatt != null || scanning) return;
        BluetoothManager bm = getSystemService(BluetoothManager.class);
        BluetoothAdapter a = bm == null ? null : bm.getAdapter();
        if (a == null || !a.isEnabled()) { badgeState = "Bluetooth éteint"; ble.postDelayed(this::scan, 3000); return; }
        BluetoothLeScanner sc = a.getBluetoothLeScanner();
        if (sc == null) { ble.postDelayed(this::scan, 3000); return; }
        badgeState = "recherche du badge… (app Galaxy Live ouverte ?)";
        scanCb = new ScanCallback() {
            @Override public void onScanResult(int type, ScanResult r) { ble.post(() -> found(r.getDevice())); }
            @Override public void onScanFailed(int code) {
                ble.post(() -> { scanning = false; badgeState = "recherche impossible (" + code + ")"; ble.postDelayed(RelayService.this::scan, 5000); });
            }
        };
        try {
            sc.startScan(Arrays.asList(new ScanFilter.Builder().setServiceUuid(new ParcelUuid(NUS)).build()),
                    new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCb);
            scanning = true;
            ble.postDelayed(() -> { if (scanning) { stopScan(); scan(); } }, 25000);   // start afresh now and then
        } catch (SecurityException e) {
            badgeState = "permission Bluetooth refusée";
            ble.postDelayed(this::scan, 5000);
        }
    }

    private void stopScan() {
        if (!scanning) return;
        scanning = false;
        try {
            BluetoothAdapter a = getSystemService(BluetoothManager.class).getAdapter();
            if (a != null && a.getBluetoothLeScanner() != null) a.getBluetoothLeScanner().stopScan(scanCb);
        } catch (Exception ignored) {}
    }

    private void found(BluetoothDevice d) {
        if (!scanning || gatt != null || stop) return;
        stopScan();
        badgeState = "connexion au badge…";
        try { gatt = d.connectGatt(this, false, gattCb, BluetoothDevice.TRANSPORT_LE); }
        catch (SecurityException e) { badgeState = "permission Bluetooth refusée"; ble.postDelayed(this::scan, 5000); }
    }

    private void lost(BluetoothGatt g) {
        try { g.close(); } catch (SecurityException ignored) {}
        if (g != gatt) return;
        gatt = null;
        rx = null;
        writing = false;
        mtu = 0;
        badgeState = "badge perdu, recherche…";
        ble.postDelayed(this::scan, 1500);
    }

    private final BluetoothGattCallback gattCb = new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt g, int status, int state) {
            ble.post(() -> {
                if (state == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    badgeState = "négociation…";
                    try {
                        g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH);
                        if (!g.requestMtu(247)) g.discoverServices();     // frames are 184 bytes: they need a big MTU
                    } catch (SecurityException e) { lost(g); }
                } else if (state == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                    lost(g);
                }
            });
        }
        @Override public void onMtuChanged(BluetoothGatt g, int m, int status) {
            ble.post(() -> { mtu = m; try { g.discoverServices(); } catch (SecurityException e) { lost(g); } });
        }
        @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
            ble.post(() -> {
                BluetoothGattService s = g.getService(NUS);
                BluetoothGattCharacteristic c = s == null ? null : s.getCharacteristic(RX);
                if (c == null) {
                    badgeState = "pas d'app Galaxy Live sur cet appareil";
                    try { g.disconnect(); } catch (SecurityException ignored) {}
                    return;
                }
                rx = c;
                badgeState = "connecté au badge" + (mtu > 0 && mtu < 187 ? " (MTU " + mtu + " : trop petit)" : "");
                pump();
            });
        }
        @Override public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            ble.post(() -> {
                writing = false;
                if (status == BluetoothGatt.GATT_SUCCESS) badgeCount.incrementAndGet();
                pump();
            });
        }
    };

    /** One write at a time: our slots first, then the newest info, then the newest frame. */
    private void pump() {
        if (gatt == null || rx == null) return;
        if (writing) {
            if (SystemClock.uptimeMillis() - writeAt < 1000) return;
            writing = false;                  // a write that never said it went: carry on
        }
        byte[] next;
        boolean isSlot = false;
        synchronized (this) {
            if (!slots.isEmpty()) { next = slots.poll(); isSlot = true; }
            else if (info != null) { next = info; info = null; }
            else if (frame != null) { next = frame; frame = null; }
            else return;
        }
        boolean ok;
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                ok = gatt.writeCharacteristic(rx, next, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothStatusCodes.SUCCESS;
            } else {
                rx.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
                rx.setValue(next);
                ok = gatt.writeCharacteristic(rx);
            }
        } catch (SecurityException e) { ok = false; }
        if (ok) { writing = true; writeAt = SystemClock.uptimeMillis(); }
        else {
            if (isSlot) synchronized (this) { slots.addFirst(next); }
            ble.postDelayed(this::pump, 20);  // the radio was busy: again in a moment
        }
    }

    private void tick() {
        relayRate = relayCount.getAndSet(0);
        badgeRate = badgeCount.getAndSet(0);
        if (++ticks % 2 == 0) {
            getSystemService(NotificationManager.class).notify(1,
                    note("Relais " + relayRate + "/s → badge " + badgeRate + "/s · " + badgeState));
        }
        if (gatt != null && rx != null) pump();
        if (!stop) ble.postDelayed(this::tick, 1000);
    }
}
