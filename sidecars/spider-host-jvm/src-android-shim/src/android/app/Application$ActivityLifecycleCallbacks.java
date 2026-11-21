package android.app;

/**
 * android.app.Application$ActivityLifecycleCallbacks 的垫片：**空接口，不声明任何方法**。
 *
 * <p>为什么是空接口：AOSP 的 7 个方法**全部**以 {@code android.app.Activity} 为参数——
 * <pre>
 *   void onActivityCreated(Activity activity, Bundle savedInstanceState);
 *   void onActivityStarted(Activity activity);
 *   void onActivityResumed(Activity activity);
 *   void onActivityPaused(Activity activity);
 *   void onActivityStopped(Activity activity);
 *   void onActivitySaveInstanceState(Activity activity, Bundle outState);
 *   void onActivityDestroyed(Activity activity);
 * </pre>
 * 本 shim 刻意**不伪造 android.app.Activity**（README §7 的 P1-2 边界：桌面端不支持碰 UI 的站源），
 * 也不用 {@code Object} 顶替参数类型：那样描述符会与 AOSP 不符，站源里本来「覆写」的方法会退化成
 * 重载，反而制造出一个看得见、却永远不被调用的假契约。
 *
 * <p>因此登记：**上述 7 个重载都需要 android.app.Activity，本垫片不提供**，理由同上。
 * 站源字节码里的影响面是可控的——实现本接口的类（{@code com.github.catvod.spider.InitOrigin$1}）
 * 自己声明了 7 个方法，接口没有声明并不妨碍它加载与实现；只有当真机侧生命周期框架去
 * {@code invokeinterface} 这 7 个方法时才会 NoSuchMethodError，而桌面端根本不会调用它们。
 *
 * <p>代价：**能加载 ≠ 行为完整**。Application#registerActivityLifecycleCallbacks 是 no-op，
 * 该接口的回调在桌面端**永不触发**；依赖「有 Activity 才继续」的站源逻辑在桌面端不会前进，
 * 调用方应如实上报缺失，而不是把「类加载成功」当成功能可用。
 *
 * <p>为什么是顶层类而不是 Application 的嵌套类：批次文件清单要求每个垫片类各占一个源文件，
 * 而 {@code $} 在 Java 标识符里合法，顶层类名为 {@code Application$ActivityLifecycleCallbacks}
 * 时产出的二进制名仍是 android/app/Application$ActivityLifecycleCallbacks.class，与 android.jar
 * 一致，dex 转译出来的字节码按二进制名链接即可命中（同 android/graphics/Bitmap$Config 的做法）。
 */
public interface Application$ActivityLifecycleCallbacks {
}
