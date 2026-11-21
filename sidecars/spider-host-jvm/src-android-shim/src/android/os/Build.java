package android.os;

/**
 * android.os.Build 的 JVM 实现垫片。
 *
 * <p><b>这是「桌面载体声称的 SDK 34」，不是真机</b>：所有常量都是垫片自己给桌面运行时声明的
 * 兼容声明面，既不读取真实硬件，也不冒充任何具体设备型号。站源用它做「Android 版本是否够新」
 * 的分支判断（{@code Build.VERSION.SDK_INT >= 29} 一类）时能拿到一致结论，但任何依赖真实
 * 型号/序列号/指纹做业务判断的代码在这里都会拿到固定的桌面值——那是设计上的取整，不是 bug。
 *
 * <p>只声明标量常量：{@code SUPPORTED_ABIS} 一族在桌面载体上没有诚实取值（JVM 的
 * {@code os.arch} 不是 Android ABI 名），按「宁可少声明也不能声明行为不符的成员」留空（见末尾登记）。
 */
public class Build {

    /** 桌面载体自报的型号；不含任何厂商标识（不是真机型号）。 */
    public static final String MODEL = "WebHTV-Desktop-JVM";

    public static final String BRAND = "WebHTV";

    public static final String MANUFACTURER = "WebHTV";

    public static final String DEVICE = "desktop";

    public static final String PRODUCT = "webhtv-desktop";

    public static final String ID = "WEBHTV-DESKTOP";

    public static final String DISPLAY = "webhtv-desktop-jvm";

    public static final String HARDWARE = "jvm";

    public static final String BOARD = "jvm";

    public static final String UNKNOWN = "unknown";

    public static final String SERIAL = UNKNOWN;

    public static final String BOOTLOADER = UNKNOWN;

    public static final String RADIO = UNKNOWN;

    public static final String CPU_ABI = "jvm";

    public static final String CPU_ABI2 = "";

    /** 与 {@link VERSION} 自洽的指纹：声明的 API 级别是 34（Android 14/REL）。 */
    public static final String FINGERPRINT = "WebHTV/webhtv_desktop/desktop:14/REL/1:user/release-keys";

    public static final String TAGS = "release-keys";

    public static final String TYPE = "user";

    public static final String HOST = "localhost";

    public static final String USER = "webhtv";

    public static final String TIME = "0";

    /** 桌面载体没有基带，也没有 ro.serialno；两者都返回 {@link #UNKNOWN}。 */
    public static String getSerial() {
        return SERIAL;
    }

    public static String getRadioVersion() {
        return RADIO;
    }

    /**
     * API 级别声明面。数值取 34（Android 14），与 {@link #FINGERPRINT} 一致；
     * {@code PREVIEW_SDK_INT = 0} 表示不是预览版（真机语义同此）。
     */
    public static class VERSION {

        public static final int SDK_INT = 34;

        public static final String SDK = "34";

        public static final String RELEASE = "14";

        public static final String CODENAME = "REL";

        public static final String INCREMENTAL = "1";

        public static final int PREVIEW_SDK_INT = 0;
    }

    // ---- 未声明成员（语义在桌面载体上无法诚实实现，或有依赖类型缺失）： ----
    // String[] SUPPORTED_ABIS / SUPPORTED_32_BIT_ABIS / SUPPORTED_64_BIT_ABIS
    //     -> JVM 的 os.arch 不是 Android ABI 名，声明就得编造取值
    // String getString(String) / getStringList -> 依赖隐藏的 system property 读取
    // VERSION_CODES 常量族 -> 只被 UI/兼容分支使用，本垫片只声明 SDK_INT=34 这一条取舍
}
