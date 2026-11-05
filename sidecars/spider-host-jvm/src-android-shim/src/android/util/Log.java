package android.util;

/**
 * android.util.Log 的 JVM 实现垫片：宿主无 logcat，统一写 stderr，避免占用 stdout 的数据通道。
 */
public final class Log {

    public static final int VERBOSE = 2;
    public static final int DEBUG = 3;
    public static final int INFO = 4;
    public static final int WARN = 5;
    public static final int ERROR = 6;
    public static final int ASSERT = 7;

    Log() {
    }

    public static int v(String tag, String msg) {
        return println(VERBOSE, tag, msg);
    }

    public static int v(String tag, String msg, Throwable tr) {
        return println(VERBOSE, tag, msg);
    }

    public static int d(String tag, String msg) {
        return println(DEBUG, tag, msg);
    }

    public static int d(String tag, String msg, Throwable tr) {
        return println(DEBUG, tag, msg);
    }

    public static int i(String tag, String msg) {
        return println(INFO, tag, msg);
    }

    public static int i(String tag, String msg, Throwable tr) {
        return println(INFO, tag, msg);
    }

    public static int w(String tag, String msg) {
        return println(WARN, tag, msg);
    }

    public static int w(String tag, String msg, Throwable tr) {
        return println(WARN, tag, msg);
    }

    public static int w(String tag, Throwable tr) {
        return println(WARN, tag, getStackTraceString(tr));
    }

    public static int e(String tag, String msg) {
        return println(ERROR, tag, msg);
    }

    public static int e(String tag, String msg, Throwable tr) {
        return println(ERROR, tag, msg);
    }

    public static int wtf(String tag, String msg) {
        return println(ASSERT, tag, msg);
    }

    public static int wtf(String tag, String msg, Throwable tr) {
        return println(ASSERT, tag, msg);
    }

    public static int wtf(String tag, Throwable tr) {
        return println(ASSERT, tag, getStackTraceString(tr));
    }

    public static String getStackTraceString(Throwable tr) {
        if (tr == null) {
            return "";
        }
        final java.io.StringWriter sw = new java.io.StringWriter();
        tr.printStackTrace(new java.io.PrintWriter(sw));
        return sw.toString();
    }

    // 垫片不做过分级过滤，恒为可输出，保证被调方逻辑路径与真机一致
    public static boolean isLoggable(String tag, int level) {
        return true;
    }

    public static int println(int priority, String tag, String msg) {
        final StringBuilder sb = new StringBuilder();
        sb.append(priorityLetter(priority)).append('/');
        sb.append(tag == null ? "null" : tag).append(": ");
        sb.append(msg == null ? "null" : msg);
        System.err.println(sb);
        return 0;
    }

    /** 带 Throwable 的重载共用同一格式化路径，栈单独输出到 stderr。 */
    static int printlnWithThrowable(int priority, String tag, String msg, Throwable tr) {
        final int rc = println(priority, tag, msg);
        if (tr != null) {
            tr.printStackTrace(System.err);
        }
        return rc;
    }

    private static char priorityLetter(int priority) {
        switch (priority) {
            case VERBOSE:
                return 'V';
            case DEBUG:
                return 'D';
            case INFO:
                return 'I';
            case WARN:
                return 'W';
            case ERROR:
                return 'E';
            case ASSERT:
                return 'A';
            default:
                return '?';
        }
    }
}
