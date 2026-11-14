package live.galaxy.relay;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.content.Intent;
import android.app.PendingIntent;
import android.content.pm.PackageManager;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.ProgressBar;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;

/** One screen: start or stop the relay, let it run in the background, see how it goes. */
public class MainActivity extends Activity {
    private TextView status, installLog;
    private ProgressBar installBar;
    private Button installBtn;
    private volatile boolean installing;
    private final Handler ui = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        int pad = dp(20);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(pad, dp(28), pad, pad);
        col.setBackgroundColor(Color.BLACK);

        View bar = new View(this);
        bar.setBackground(new GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, new int[] {0xFF9945FF, 0xFF14F195}));
        col.addView(bar, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(4)));

        col.addView(text("Firedancer Badge", 28, Color.WHITE, true), margins(0, dp(16), 0, dp(4)));
        col.addView(text("Installe l'app sur le badge en USB, puis envoie-lui les données du dashboard Firedancer en Bluetooth, "
                + "même quand tu utilises une autre app.", 15, 0xFF8E8C9E, false), margins(0, 0, 0, dp(16)));

        col.addView(text("1. Installer sur le badge (USB)", 18, Color.WHITE, true), margins(0, dp(8), 0, dp(2)));
        col.addView(text("Badge branché au téléphone en USB-C, microSD en place.", 14, 0xFF8E8C9E, false));
        installBtn = button("Installer l'app sur le badge", true, v -> install());
        col.addView(installBtn, margins(0, dp(10), 0, dp(6)));
        installBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        installBar.setMax(1000);
        installBar.setVisibility(View.GONE);
        col.addView(installBar, margins(0, dp(4), 0, dp(4)));
        installLog = text("", 13, 0xFF8E8C9E, false);
        installLog.setTypeface(Typeface.MONOSPACE);
        col.addView(installLog, margins(0, 0, 0, dp(12)));

        col.addView(text("2. Relais en direct (Bluetooth)", 18, Color.WHITE, true), margins(0, dp(8), 0, dp(2)));
        col.addView(text("L'app Firedancer ouverte sur le badge.", 14, 0xFF8E8C9E, false));
        col.addView(button("Démarrer le relais", true, v -> start()), margins(0, dp(10), 0, dp(6)));
        col.addView(button("Arrêter", false, v -> stopService(new Intent(this, RelayService.class))), margins(0, dp(6), 0, dp(6)));
        col.addView(button("Ne pas couper en arrière-plan (batterie)", false, v -> battery()), margins(0, dp(6), 0, dp(16)));

        status = text("", 14, 0xFFB6B0FF, false);
        status.setTypeface(Typeface.MONOSPACE);
        col.addView(status);

        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(Color.BLACK);
        sv.addView(col);
        setContentView(sv);
        refresh();
    }

    private void refresh() {
        PowerManager pm = getSystemService(PowerManager.class);
        boolean free = pm.isIgnoringBatteryOptimizations(getPackageName());
        status.setText("Relais : " + RelayService.relayState + "\n"
                + "Badge  : " + RelayService.badgeState + "\n\n"
                + "Relais → téléphone : " + RelayService.relayRate + " messages/s\n"
                + "Téléphone → badge  : " + RelayService.badgeRate + " messages/s\n"
                + (RelayService.mtu > 0 ? "MTU Bluetooth : " + RelayService.mtu + "\n" : "")
                + "\nArrière-plan : " + (free ? "autorisé" : "limité par la batterie (bouton ci-dessus)"));
        ui.postDelayed(this::refresh, 1000);
    }

    @Override protected void onDestroy() { ui.removeCallbacksAndMessages(null); super.onDestroy(); }

    // ------------------------------------------------------------------ installing on the badge (USB)

    private void ilog(String s, int kind) {
        ui.post(() -> {
            String mark = kind == 1 ? "✓ " : kind == 2 ? "✗ " : "· ";
            installLog.append(mark + s + "\n");
            if (kind == 2) installLog.setTextColor(0xFFEB54BC);
        });
    }

    private void install() {
        if (installing) return;
        UsbManager um = getSystemService(UsbManager.class);
        UsbDevice dev = null;
        for (UsbDevice d : um.getDeviceList().values()) if (d.getVendorId() == Ch340.VENDOR) dev = d;
        installLog.setText("");
        installLog.setTextColor(0xFF8E8C9E);
        if (dev == null) { ilog("Badge introuvable en USB : branche-le au téléphone (USB-C, adaptateur OTG si besoin).", 2); return; }
        if (!um.hasPermission(dev)) {
            Intent i = new Intent("live.galaxy.relay.USB").setPackage(getPackageName());
            um.requestPermission(dev, PendingIntent.getBroadcast(this, 0, i, Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0));
            ilog("Autorise l'accès au badge dans la fenêtre d'Android…", 0);
        }
        installing = true;
        installBtn.setEnabled(false);
        installBtn.setAlpha(0.5f);
        installBar.setProgress(0);
        installBar.setVisibility(View.VISIBLE);
        final UsbDevice badge = dev;
        new Thread(() -> {
            Ch340 port = null;
            try {
                for (int i = 0; i < 200 && !um.hasPermission(badge); i++) Thread.sleep(300);   // up to a minute to answer
                if (!um.hasPermission(badge)) throw new Installer.Failed("accès USB refusé", true);
                Installer[] ins = new Installer[1];
                port = new Ch340(um, badge);
                ins[0] = new Installer(port, new Installer.Log() {
                    @Override public void line(String s, int kind) { ilog(s, kind); }
                    @Override public void progress(double p) { ui.post(() -> installBar.setProgress((int) (p * 1000))); }
                });
                port.start(ins[0]);
                ins[0].run(Config.HOST);
                ui.post(() -> installBar.setProgress(1000));
                ilog("Passe à l'étape 2 : démarre le relais.", 1);
            } catch (Exception e) {
                ilog("Erreur : " + e.getMessage(), 2);
            } finally {
                if (port != null) port.close();
                ui.post(() -> { installing = false; installBtn.setEnabled(true); installBtn.setAlpha(1f); });
            }
        }, "install").start();
    }

    // ------------------------------------------------------------------ starting

    private void start() {
        List<String> need = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 31) {
            need.add(Manifest.permission.BLUETOOTH_SCAN);
            need.add(Manifest.permission.BLUETOOTH_CONNECT);
        } else {
            need.add(Manifest.permission.ACCESS_FINE_LOCATION);
        }
        if (Build.VERSION.SDK_INT >= 33) need.add(Manifest.permission.POST_NOTIFICATIONS);
        List<String> missing = new ArrayList<>();
        for (String p : need) if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) missing.add(p);
        if (!missing.isEmpty()) { requestPermissions(missing.toArray(new String[0]), 1); return; }
        BluetoothAdapter a = getSystemService(BluetoothManager.class).getAdapter();
        if (a != null && !a.isEnabled()) {
            try { startActivityForResult(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), 2); } catch (SecurityException ignored) {}
            return;
        }
        startForegroundService(new Intent(this, RelayService.class));
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        for (int i = 0; i < perms.length; i++) {
            if (res[i] != PackageManager.PERMISSION_GRANTED && !perms[i].equals(Manifest.permission.POST_NOTIFICATIONS)) {
                RelayService.badgeState = "permission refusée : " + perms[i].replace("android.permission.", "");
                return;
            }
        }
        start();
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        if (code == 2 && result == RESULT_OK) start();
    }

    private void battery() {
        PowerManager pm = getSystemService(PowerManager.class);
        if (pm.isIgnoringBatteryOptimizations(getPackageName())) return;
        try {
            startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName())));
        } catch (Exception e) {
            startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
        }
    }

    // ------------------------------------------------------------------ views

    private int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }

    private LinearLayout.LayoutParams margins(int l, int t, int r, int b) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        p.setMargins(l, t, r, b);
        return p;
    }

    private TextView text(String s, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        return t;
    }

    private Button button(String label, boolean main, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(16);
        b.setTextColor(main ? Color.BLACK : Color.WHITE);
        GradientDrawable bg = main
                ? new GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, new int[] {0xFF9945FF, 0xFF14F195})
                : new GradientDrawable();
        if (!main) { bg.setColor(0xFF111116); bg.setStroke(dp(1), 0xFF2A2935); }
        bg.setCornerRadius(dp(12));
        b.setBackground(bg);
        b.setGravity(Gravity.CENTER);
        b.setPadding(0, dp(14), 0, dp(14));
        b.setOnClickListener(l);
        return b;
    }
}
