package dev.gabe284.nnapiprobe;

import android.app.Activity;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.ScrollView;
import android.widget.TextView;

public final class MainActivity extends Activity {
    static {
        System.loadLibrary("nnapi_probe");
    }

    private TextView output;

    private static native String nativeProbe();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        output = new TextView(this);
        output.setTextSize(14);
        output.setTextIsSelectable(true);
        output.setPadding(24, 24, 24, 24);
        output.setGravity(Gravity.TOP);
        output.setText("Running NNAPI device enumeration and per-device ADD test…");

        ScrollView scroll = new ScrollView(this);
        scroll.addView(output);
        setContentView(scroll);

        Thread worker = new Thread(() -> {
            String report;
            try {
                report = nativeProbe();
            } catch (Throwable error) {
                report = "FATAL: " + error;
            }
            final String result = report;
            runOnUiThread(() -> output.setText(result));
        }, "NNAPI-Probe");
        worker.start();
    }
}
