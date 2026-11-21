package android.app;

import android.content.Context;
import android.content.SharedPreferences;

import java.io.File;

/**
 * android.app.Activity 的**类型垫片**：只保证类型可解析，不提供任何 UI/生命周期语义。
 *
 * <p>为什么必须存在：加固壳载荷的 {@code com.github.catvod.spider.InitOrigin} 有字段
 * {@code public android.app.Activity d}。JVM 在**解析该类的字段**时要把所有字段类型都
 * resolve 一次，缺 Activity 就是 {@code NoClassDefFoundError: android/app/Activity}——
 * 于是连 {@code InitOrigin.context()} 的上下文注入都做不了（实测：
 * {@code getDeclaredField("c")} 直接抛这个错）。这不是「要跑 UI」，而是**类型系统**要求。
 *
 * <p>边界（逐条生效）：
 * - 不模拟 Activity 生命周期：{@code onCreate/onResume/...} 一律没有，回调不会发生；
 * - 不提供 Window/View 体系：{@link #getWindow()} 返回 null；
 * - 存储类访问器按「没有 base Context」如实抛 {@link UnsupportedOperationException}，
 *   不返回假路径（返回 null 会让站源以为读到了空配置）。
 * - 站源若真的依赖 Activity 交互，桌面端应当**如实失败**，而不是被这个类蒙混过关。
 */
public class Activity extends Context {

    /** 桌面端没有 ActivityThread；这里只保留一个可返回的 Application（可能为 null）。 */
    private Application application;

    public Activity() {
    }

    /** 类型垫片专用：绑定一个 Application（通常就是宿主注入的那个）。 */
    public void attachApplication(Application application) {
        this.application = application;
    }

    public Application getApplication() {
        return application;
    }

    /** AOSP 里它来自 ContextWrapper（本垫片没有那个中间层），所以不加 @Override。 */
    public Context getApplicationContext() {
        return application != null ? application : this;
    }

    /** 真机上切到主线程；桌面端已经在宿主线程上，直接同步执行并说明。 */
    public void runOnUiThread(Runnable action) {
        if (action != null) action.run();
    }

    /** 桌面端没有可关闭的窗口：返回 false（“未在关闭中”是诚实的默认）。 */
    public boolean isFinishing() {
        return false;
    }

    /** 没有窗口/任务栈可结束：no-op 并说明，避免伪装成“已关闭”。 */
    public void finish() {
        System.err.println("[webhtv-shim] android.app.Activity#finish: no-op —— 桌面 sidecar 没有 Activity/任务栈");
    }

    /** 没有 Window 体系（见类注释的边界）。 */
    public Object getWindow() {
        return null;
    }

    // ---- Context 抽象成员：没有 base Context 时如实抛出 ----

    @Override
    public SharedPreferences getSharedPreferences(String name, int mode) {
        if (application != null) return application.getSharedPreferences(name, mode);
        throw unsupported("getSharedPreferences");
    }

    @Override
    public File getFilesDir() {
        if (application != null) return application.getFilesDir();
        throw unsupported("getFilesDir");
    }

    @Override
    public File getCacheDir() {
        if (application != null) return application.getCacheDir();
        throw unsupported("getCacheDir");
    }

    @Override
    public String getPackageName() {
        return application != null ? application.getPackageName() : Application.PACKAGE_NAME;
    }

    @Override
    public Object getSystemService(String name) {
        if (application != null) return application.getSystemService(name);
        throw unsupported("getSystemService");
    }

    private static UnsupportedOperationException unsupported(String member) {
        return new UnsupportedOperationException("android.app.Activity#" + member
                + "：桌面 sidecar 没有 ActivityThread / base Context，取不到真实存储与系统服务；"
                + "本垫片不返回假值以免静默成功");
    }
}