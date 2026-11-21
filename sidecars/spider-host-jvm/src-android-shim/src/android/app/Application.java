package android.app;

import android.content.Context;
import android.content.SharedPreferences;

import java.io.File;

/**
 * android.app.Application 的垫片：只保证**类型可解析 + 非 UI 的最小面**，行为一律如实 no-op/抛出。
 *
 * <p>为什么需要它：站源 {@code com.github.catvod.spider.InitOrigin} 有字段
 * {@code android.app.Application c}、静态方法 {@code context()}，并在
 * {@code init(Context)} 里把收到的 Context {@code checkcast} 成 Application 后调用
 * {@code registerActivityLifecycleCallbacks}。桌面 sidecar 里没有系统创建的 Application
 * 实例，但**这两个名字必须解析得到**，否则实现 {@code Application$ActivityLifecycleCallbacks}
 * 的站源类（InitOrigin$1 等）连加载都过不去（NoClassDefFoundError）。
 *
 * <p>代价必须说清：**能加载 ≠ 行为完整**。真机上 Application 由 ActivityThread 构造、携带
 * 全进程的状态；这里没有任何实例被创建，注册回调是 no-op，生命周期回调**永远不会发生**。
 * 站源若把「Activity 出现后再继续」当成功前提，桌面端不会得到任何回调——调用方应如实上报
 * 「桌面端无 Activity 生命周期」，不要把它当成成功。
 *
 * <p>继承关系：AOSP 是 {@code Application extends ContextWrapper extends Context}。本 shim
 * 没有 ContextWrapper，因此直接 {@code extends Context}；这一步不是可选的——站源字节码会对
 * Application 类型的值调用 {@code android/content/Context.getFilesDir} 等成员，若 Application
 * 不是 Context，校验器会直接判 VerifyError。Context 的抽象存储访问器在这里只能抛
 * {@link UnsupportedOperationException}：桌面端没有 base Context，编一个返回 null 的实现会让
 * 站源以为「读到了空目录/空配置」，那才是静默失败。
 *
 * <p>刻意不提供：Activity/Window/View 相关能力、{@code ContextWrapper}、
 * {@code attachBaseContext}、{@code onCreate/onTerminate}、{@code onConfigurationChanged}、
 * {@code registerOnProvideAssistDataListener} 等其余 AOSP 成员（站源零引用，且桌面端给不出诚实语义）。
 */
public class Application extends Context {

    /** 桌面载体的固定包名：与 {@link android.content.WebhtvContext#getPackageName()} 同源，避免两处取值漂移。 */
    public static final String PACKAGE_NAME = "webhtv.spider.host";

    private static final String TAG = "[webhtv-shim] android.app.Application";

    public Application() {
        // AOSP 有公开无参构造器；真机上 Application 由 ActivityThread 创建，桌面端不会被实例化。
        this(null);
    }

    /**
     * 桌面载体专用：包一个真实可用的 base Context（宿主注入的 {@code WebhtvContext}）。
     *
     * <p>为什么需要：壳载荷里的 {@code InitOrigin.context()} 返回的 Application 会被站源直接拿去
     * {@code getSharedPreferences(...)}（实测 wex 系在 {@code playerContent} 里就这么做）。
     * 没有 base 时那个调用只能抛 {@link UnsupportedOperationException}，等于“站点能出首页、播不了”；
     * 包上 base 之后这些存储访问走宿主的站点目录，行为是真实的，而不是假成功。
     */
    public Application(Context base) {
        this.base = base;
    }

    /** 宿主注入的 base Context；为 null 表示“纯类型占位”（成员按未支持处理）。 */
    private final Context base;

    /**
     * AOSP 返回 {@code Context}（Application 自身）。这里返回 this：类型上仍是 Context，
     * 与真机一致；桌面端没有任何 base Context 可返回。
     */
    public Context getApplicationContext() {
        return this;
    }

    @Override
    public String getPackageName() {
        return base == null ? PACKAGE_NAME : base.getPackageName();
    }

    /**
     * 真机上把这套回调挂到进程的 Activity 生命周期上；桌面端没有 Activity，注册只能是 no-op，
     * 因此这里**打一条 stderr**：静默 no-op 会让上层以为回调已经生效。
     */
    public void registerActivityLifecycleCallbacks(Application$ActivityLifecycleCallbacks callback) {
        System.err.println(TAG + "#registerActivityLifecycleCallbacks: no-op —— 桌面 sidecar 无 Activity 生命周期，"
                + "该回调不会被调用（callback=" + (callback == null ? "null" : callback.getClass().getName()) + "）");
    }

    /** 对称的 no-op：注册本来就没生效，注销无需额外告警。 */
    public void unregisterActivityLifecycleCallbacks(Application$ActivityLifecycleCallbacks callback) {
        // 无状态：见 registerActivityLifecycleCallbacks 的说明。
    }

    // ---- Context 的抽象成员：桌面端给不出诚实取值，一律点名抛出而不是返回空对象 ----

    @Override
    public SharedPreferences getSharedPreferences(String name, int mode) {
        if (base != null) return base.getSharedPreferences(name, mode);
        throw unsupported("getSharedPreferences");
    }

    @Override
    public File getFilesDir() {
        if (base != null) return base.getFilesDir();
        throw unsupported("getFilesDir");
    }

    @Override
    public File getCacheDir() {
        if (base != null) return base.getCacheDir();
        throw unsupported("getCacheDir");
    }

    @Override
    public Object getSystemService(String name) {
        if (base != null) return base.getSystemService(name);
        throw unsupported("getSystemService");
    }

    private static UnsupportedOperationException unsupported(String member) {
        return new UnsupportedOperationException("android.app.Application#" + member
                + "：桌面 sidecar 没有系统创建的 Application / base Context，取不到真实存储与系统服务；"
                + "本垫片不返回假值以免静默成功");
    }
}
