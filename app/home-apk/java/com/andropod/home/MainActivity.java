package com.andropod.home;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.GridLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * AndroPod 的模拟器桌面（仿 MuMu 的产品层）：暖色渐变壁纸、大时钟、应用网格。
 * 纯框架 API、程序化布局——整个桌面就是一个 Activity，无依赖、无资源文件。
 */
public class MainActivity extends Activity {

    private static final int COLUMNS = 6;

    private final Handler clock = new Handler(Looper.getMainLooper());
    private TextView timeView;
    private TextView dateView;
    private SimpleDateFormat timeFormat;
    private SimpleDateFormat dateFormat;

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            Date now = new Date();
            timeView.setText(timeFormat.format(now));
            dateView.setText(dateFormat.format(now));
            clock.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        /* 沉浸：内容延伸进状态栏/导航栏区域（MuMu 的观感：系统 UI 不占位）。 */
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN);

        Locale locale = getResources().getConfiguration().getLocales().get(0);
        timeFormat = new SimpleDateFormat("HH:mm", locale);
        dateFormat = new SimpleDateFormat("M月d日 EEEE", locale);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(dp(56), dp(48), dp(56), dp(24));
        root.setBackground(wallpaper());

        timeView = bigClock();
        root.addView(timeView);

        dateView = new TextView(this);
        dateView.setTextColor(Color.argb(0xde, 0xff, 0xff, 0xff));
        dateView.setTextSize(15);
        dateView.setPadding(0, dp(4), 0, 0);
        root.addView(dateView);

        root.addView(spacer(dp(36)));

        /* 应用网格放在滚动容器里：应用多时可以上下滑。 */
        ScrollView scroller = new ScrollView(this);
        scroller.setVerticalScrollBarEnabled(false);
        GridLayout grid = new GridLayout(this);
        grid.setColumnCount(COLUMNS);
        grid.setUseDefaultMargins(false);
        List<ResolveInfo> apps = launcherApps();
        for (int i = 0; i < apps.size(); i++) {
            grid.addView(appCell(apps.get(i)), gridParams(i));
        }
        scroller.addView(grid,
                new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(scroller, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        root.addView(quickBar());

        setContentView(root);
        clock.post(tick);
    }

    /* 大号半透明白时钟——MuMu 锁屏/桌面的视觉锚点。 */
    private TextView bigClock() {
        TextView v = new TextView(this);
        v.setTextColor(Color.argb(0xf2, 0xff, 0xff, 0xff));
        v.setTextSize(72);
        v.setTypeface(Typeface.create("sans-serif-light", Typeface.BOLD));
        v.setShadowLayer(dp(6), 0, dp(2), Color.argb(0x66, 0x00, 0x00, 0x00));
        v.setGravity(Gravity.CENTER);
        return v;
    }

    /* 应用格子：56dp 圆角白底 + 图标 + 单行名字。 */
    private View appCell(final ResolveInfo info) {
        PackageManager pm = getPackageManager();
        LinearLayout cell = new LinearLayout(this);
        cell.setOrientation(LinearLayout.VERTICAL);
        cell.setGravity(Gravity.CENTER_HORIZONTAL);
        cell.setPadding(dp(10), dp(14), dp(10), dp(14));

        ImageView icon = new ImageView(this);
        icon.setImageDrawable(info.loadIcon(pm));
        icon.setScaleType(ImageView.ScaleType.FIT_CENTER);

        TextView name = new TextView(this);
        name.setText(info.loadLabel(pm));
        name.setTextColor(Color.argb(0xf0, 0xff, 0xff, 0xff));
        name.setTextSize(12);
        name.setMaxLines(1);
        name.setEllipsize(TextUtils.TruncateAt.END);
        name.setPadding(0, dp(8), 0, 0);
        name.setShadowLayer(dp(4), 0, dp(1), Color.argb(0x55, 0x00, 0x00, 0x00));

        cell.addView(icon, new LinearLayout.LayoutParams(dp(52), dp(52)));
        cell.addView(name, new LinearLayout.LayoutParams(dp(84), ViewGroup.LayoutParams.WRAP_CONTENT));

        cell.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                Intent launch = pm.getLaunchIntentForPackage(
                        info.activityInfo.packageName);
                if (launch != null) startActivity(launch);
            }
        });
        return cell;
    }

    /* 底部快捷条：设置 + 应用市场占位（以后接 AndroPod 工具）。 */
    private View quickBar() {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER);
        bar.setPadding(0, dp(10), 0, dp(6));

        bar.addView(shortcut("设置", new Intent(Settings.ACTION_SETTINGS)));
        bar.addView(spacer(dp(18)));
        bar.addView(shortcut("应用商店", new Intent(Intent.ACTION_VIEW,
                Uri.parse("https://appgallery.huawei.com"))));
        return bar;
    }

    private View shortcut(String label, final Intent intent) {
        TextView v = new TextView(this);
        v.setText(label);
        v.setTextColor(Color.argb(0xe6, 0xff, 0xff, 0xff));
        v.setTextSize(13);
        v.setGravity(Gravity.CENTER);
        v.setPadding(dp(20), dp(8), dp(20), dp(8));
        GradientDrawable pill = new GradientDrawable();
        pill.setColor(Color.argb(0x59, 0x00, 0x00, 0x00));
        pill.setCornerRadius(dp(20));
        v.setBackground(pill);
        v.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View view) {
                try {
                    startActivity(intent);
                } catch (Exception ignored) {
                }
            }
        });
        return v;
    }

    /* 暖金→深橄榄的对角渐变，接近 MuMu 桌面的底色。 */
    private GradientDrawable wallpaper() {
        GradientDrawable g = new GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                new int[] {
                        Color.rgb(0xe8, 0xc9, 0x74),
                        Color.rgb(0xc9, 0xa9, 0x55),
                        Color.rgb(0x7a, 0x6d, 0x38),
                });
        g.setGradientRadius(dp(900));
        return g;
    }

    private View spacer(int height) {
        View v = new View(this);
        v.setLayoutParams(new LinearLayout.LayoutParams(1, height));
        return v;
    }

    private GridLayout.LayoutParams gridParams(int index) {
        GridLayout.LayoutParams p = new GridLayout.LayoutParams();
        p.width = dp(104);
        p.height = ViewGroup.LayoutParams.WRAP_CONTENT;
        p.columnSpec = GridLayout.spec(index % COLUMNS);
        p.rowSpec = GridLayout.spec(index / COLUMNS);
        return p;
    }

    private List<ResolveInfo> launcherApps() {
        Intent main = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> all = getPackageManager().queryIntentActivities(main, 0);
        List<ResolveInfo> result = new ArrayList<>();
        for (ResolveInfo info : all) {
            /* 自己不进网格：桌面上再放一个桌面入口是噪音。 */
            if (!getPackageName().equals(info.activityInfo.packageName)) {
                result.add(info);
            }
        }
        return result;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    protected void onDestroy() {
        clock.removeCallbacks(tick);
        super.onDestroy();
    }
}
