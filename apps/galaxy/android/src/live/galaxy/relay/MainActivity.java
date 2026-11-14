package live.galaxy.relay;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.content.Intent;
import android.content.pm.PackageManager;
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
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;

/** One screen: start or stop the relay, let it run in the background, see how it goes. */
public class MainActivity extends Activity {
    private TextView status;
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

        col.addView(text("Galaxy Live", 28, Color.WHITE, true), margins(0, dp(16), 0, dp(4)));
        col.addView(text("Envoie les slots de Galaxy au badge en Bluetooth, même quand tu utilises une autre app. "
                + "Ouvre l'app Galaxy Live sur le badge, puis démarre le relais.", 15, 0xFF8E8C9E, false), margins(0, 0, 0, dp(16)));

        col.addView(button("Démarrer le relais", true, v -> start()), margins(0, dp(6), 0, dp(6)));
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
