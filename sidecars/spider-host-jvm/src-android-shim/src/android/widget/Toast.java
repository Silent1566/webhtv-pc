package android.widget;

import android.content.Context;

/** Notification-only desktop substitution; no Android UI, resources, timers or retained Context. */
public final class Toast {
    public static final int LENGTH_SHORT = 0;
    public static final int LENGTH_LONG = 1;
    private static final int MAX_MESSAGE_CHARS = 512;

    private final String message;

    private Toast(CharSequence text) {
        message = sanitize(text);
    }

    /** Duration has no effect because the notification is a single stderr diagnostic, not a window. */
    public static Toast makeText(Context context, CharSequence text, int duration) {
        return new Toast(text);
    }

    public void show() {
        System.err.println("[webhtv-shim] android.widget.Toast#show: desktop notification substitution (stderr only; no UI): " + message);
    }

    public void cancel() {
        // There is no pending UI or timer to cancel, and an emitted diagnostic cannot be retracted.
    }

    private static String sanitize(CharSequence text) {
        if (text == null) return "null";
        int length = text.length();
        int limit = Math.min(length, MAX_MESSAGE_CHARS);
        StringBuilder result = new StringBuilder(limit + 3);
        int index = 0;
        while (index < limit) {
            int codePoint = Character.codePointAt(text, index);
            int width = Character.charCount(codePoint);
            if (width > limit - index) break;
            int type = Character.getType(codePoint);
            if (Character.isISOControl(codePoint) || type == Character.FORMAT
                    || type == Character.LINE_SEPARATOR || type == Character.PARAGRAPH_SEPARATOR) {
                result.append(' ');
            } else if (type == Character.SURROGATE) {
                result.append('?');
            } else {
                result.appendCodePoint(codePoint);
            }
            index += width;
        }
        if (index < length) result.append("...");
        return result.toString();
    }
}
