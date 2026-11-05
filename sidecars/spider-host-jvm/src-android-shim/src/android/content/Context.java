package android.content;

import java.io.File;

/**
 * android.content.Context 的垫片（javap 确认是 abstract class，不是接口）。
 *
 * <p>站源只把 Context 当参数类型接收（Spider#init、View/Window 构造器），从不实例化，
 * 所以这里保持 abstract，只声明站源可能真正调用的存储相关方法。
 *
 * <p>方法一律声明成 abstract 而不是给默认实现：Context 的真实存放位置由宿主决定，
 * 垫片给不出有意义的默认值；一个返回 null 的默认实现会让站源以为「读到了空配置」，
 * 而把「没人实现」变成抽象方法，问题会在编译期/实例化时暴露。
 */
public abstract class Context {

    // 取值照 javap -constants，站源会拿 MODE_PRIVATE 直接传给 getSharedPreferences。
    public static final int MODE_PRIVATE = 0;
    public static final int MODE_WORLD_READABLE = 1;
    public static final int MODE_WORLD_WRITEABLE = 2;
    public static final int MODE_MULTI_PROCESS = 4;
    public static final int MODE_APPEND = 32768;

    public Context() {
        // 真机构造器是包级私有的，由系统创建；这里公开无参构造器，子类 extends 时不必再造桥接构造器。
    }

    public abstract SharedPreferences getSharedPreferences(String name, int mode);

    public abstract File getFilesDir();

    public abstract File getCacheDir();

    public abstract String getPackageName();

    public abstract Object getSystemService(String name);

    // 不声明成 abstract：真机器里 Context 的存放位置由宿主决定，但 getApplicationInfo() 的返回值
    // 语义已被站源固定为「读 packageName」，与 getPackageName() 同源，垫片给得出正确默认值；
    // 声明成 abstract 只会强迫每个 Context 子类补一个空实现，扩大改动面。
    public android.content.pm.ApplicationInfo getApplicationInfo() {
        android.content.pm.ApplicationInfo info = new android.content.pm.ApplicationInfo();
        info.packageName = getPackageName();
        return info;
    }

    // ---- 未声明成员： ----
    // getApplicationContext()/getClassLoader()/createDeviceProtectedStorageContext()/
    // getSystemServiceName(Class)/getSystemService(Class)/isUiContext()
    //   -> 站源与 android/view/** 零引用，按实际使用裁剪。
}
