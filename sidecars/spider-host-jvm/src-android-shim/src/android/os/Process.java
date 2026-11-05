package android.os;

/**
 * android.os.Process 的桌面真实现。
 *
 * <p>站源/解密模块常用 myPid()/myTid() 做「每进程一次」的判定，或把 pid 拼进缓存 key。
 * 桌面 JVM 上没有 getpid() 这个 native 入口，但 Java 9+ 的 {@link ProcessHandle}
 * 能拿到同样的信息，于是这里返回**真实值**而不是常量 0（返回 0 会让「首次初始化」
 * 判定总是失败，且 pid 拼出的 key 全部相撞）。
 *
 * <p>优先级相关的方法是空操作：桌面线程优先级与 Android 的 nice 值不是一套东西，
 * 强行映射只会改到宿主自己的调度策略。
 */
public class Process {

    public static final int BLUETOOTH_UID = 1002;
    public static final int FIRST_APPLICATION_UID = 10000;
    public static final int INVALID_PID = -1;
    public static final int INVALID_UID = -1;
    public static final int LAST_APPLICATION_UID = 19999;
    public static final int PHONE_UID = 1001;
    public static final int ROOT_UID = 0;
    public static final int SHELL_UID = 2000;
    public static final int SIGNAL_KILL = 9;
    public static final int SIGNAL_QUIT = 3;
    public static final int SIGNAL_USR1 = 10;
    public static final int SYSTEM_UID = 1000;
    public static final int THREAD_PRIORITY_AUDIO = -16;
    public static final int THREAD_PRIORITY_BACKGROUND = 10;
    public static final int THREAD_PRIORITY_DEFAULT = 0;
    public static final int THREAD_PRIORITY_DISPLAY = -4;
    public static final int THREAD_PRIORITY_FOREGROUND = -2;
    public static final int THREAD_PRIORITY_LESS_FAVORABLE = 1;
    public static final int THREAD_PRIORITY_LOWEST = 19;
    public static final int THREAD_PRIORITY_MORE_FAVORABLE = -1;
    public static final int THREAD_PRIORITY_URGENT_AUDIO = -19;
    public static final int THREAD_PRIORITY_URGENT_DISPLAY = -8;
    public static final int THREAD_PRIORITY_VIDEO = -10;
    public static final int WIFI_UID = 1010;

    /** 桌面没有独立的 uid 概念，用宿主进程 pid 充当，保证同一进程内稳定。 */
    private static final int FAKE_UID = 10000;

    public Process() {
        // javap 显示真机有这个 public 构造器，保留以兼容反射。
    }

    public static final int myPid() {
        return (int) ProcessHandle.current().pid();
    }

    public static final int myTid() {
        // 真机上 myTid 是线程 id；Java 侧没有跨平台的线程 id 接口，
        // 用线程名 + 平台线程号哈希无意义，这里退化为进程 pid（同一线程内调用结果稳定）。
        return myPid();
    }

    public static final int myUid() {
        return FAKE_UID;
    }

    public static String myProcessName() {
        return ProcessHandle.current().info().command().orElse("webhtv-spider-host");
    }

    public static final void setThreadPriority(int priority) {
        // 空操作：Android 的线程优先级是 nice 值语义，桌面改它会影响宿主整体调度。
    }

    public static final void setThreadPriority(int tid, int priority) {
        // 同上。
    }

    public static final int getThreadPriority(int tid) {
        return THREAD_PRIORITY_DEFAULT;
    }

    public static final boolean is64Bit() {
        return "64".equals(System.getProperty("sun.arch.data.model"));
    }

    public static final long getElapsedCpuTime() {
        // 真机返回进程 CPU 时间（毫秒）；桌面用 JVM 运行时长近似，语义足够用。
        return java.lang.management.ManagementFactory.getRuntimeMXBean().getUptime();
    }

    public static final int[] getExclusiveCores() {
        // 桌面无法查询 Android 的 exclusive core 集合，返回空数组表示「未知」，
        // 与真机在不支持的设备上的行为一致。
        return new int[0];
    }

    public static final int getUidForName(String name) {
        return name == null ? INVALID_UID : -1;
    }

    public static final int getGidForName(String name) {
        return name == null ? INVALID_UID : -1;
    }

    public static final void killProcess(int pid) {
        // 桌面垫片绝不真的杀进程：站源里偶尔用 killProcess(myPid()) 做「退出」，
        // 照做会把宿主一起杀掉。只记 stderr。
        System.err.println("[android-shim] Process.killProcess(" + pid + ") 被忽略");
    }

    public static final void sendSignal(int pid, int signal) {
        // 同上，信号语义在桌面不映射。
        System.err.println("[android-shim] Process.sendSignal(" + pid + ", " + signal + ") 被忽略");
    }

    public static final boolean isApplicationUid(int uid) {
        return uid >= FIRST_APPLICATION_UID && uid <= LAST_APPLICATION_UID;
    }

    public static final boolean isIsolated() {
        return false;
    }

    public static final boolean isIsolatedUid(int uid) {
        return false;
    }

    public static final boolean isSdkSandbox() {
        return false;
    }

    public static final boolean isSdkSandboxUid(int uid) {
        return false;
    }

    public static final int getAppUidForSdkSandboxUid(int uid) {
        return uid;
    }

    public static final int getSdkSandboxUidForAppUid(int uid) {
        return uid;
    }

    public static final boolean supportsProcesses() {
        return true;
    }

    public static long getStartElapsedRealtime() {
        return java.lang.management.ManagementFactory.getRuntimeMXBean().getStartTime();
    }

    public static long getStartUptimeMillis() {
        return java.lang.management.ManagementFactory.getRuntimeMXBean().getStartTime();
    }

    public static long getStartRequestedElapsedRealtime() {
        return getStartElapsedRealtime();
    }

    public static long getStartRequestedUptimeMillis() {
        return getStartUptimeMillis();
    }

    // ---- 未声明成员：public static UserHandle myUserHandle() ----
    // 依赖 android.os.UserHandle（仓库内尚缺），故按 javap 留空并在此登记。
}
