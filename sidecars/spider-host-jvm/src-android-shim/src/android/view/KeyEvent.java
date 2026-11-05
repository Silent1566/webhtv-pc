package android.view;

public class KeyEvent {

    public interface Callback {
        boolean onKeyDown(int keyCode, KeyEvent event);

        boolean onKeyLongPress(int keyCode, KeyEvent event);

        boolean onKeyMultiple(int keyCode, int repeatCount, KeyEvent event);

        boolean onKeyUp(int keyCode, KeyEvent event);
    }

    public static final int ACTION_DOWN = 0;
    public static final int ACTION_MULTIPLE = 2;
    public static final int ACTION_UP = 1;

    public static final int FLAG_CANCELED = 32;
    public static final int FLAG_CANCELED_LONG_PRESS = 256;
    public static final int FLAG_LONG_PRESS = 128;

    public static final int MAX_KEYCODE = 84;

    public static final int KEYCODE_BACK = 4;
    public static final int KEYCODE_DEL = 67;
    public static final int KEYCODE_DPAD_CENTER = 23;
    public static final int KEYCODE_DPAD_DOWN = 20;
    public static final int KEYCODE_DPAD_LEFT = 21;
    public static final int KEYCODE_DPAD_RIGHT = 22;
    public static final int KEYCODE_DPAD_UP = 19;
    public static final int KEYCODE_ENTER = 66;
    public static final int KEYCODE_MEDIA_NEXT = 87;
    public static final int KEYCODE_MEDIA_PLAY_PAUSE = 85;
    public static final int KEYCODE_MEDIA_PREVIOUS = 88;
    public static final int KEYCODE_MENU = 82;
    public static final int KEYCODE_SEARCH = 84;
    public static final int KEYCODE_SPACE = 62;
    public static final int KEYCODE_TAB = 61;
    public static final int KEYCODE_VOLUME_DOWN = 25;
    public static final int KEYCODE_VOLUME_MUTE = 164;
    public static final int KEYCODE_VOLUME_UP = 24;

    private final long mDownTime;
    private final long mEventTime;
    private final int mAction;
    private final int mKeyCode;
    private final int mRepeatCount;
    private final int mMetaState;
    private final int mScanCode;
    private final int mFlags;
    private final int mDeviceId;
    private final int mSource;
    private final String mCharacters;

    private boolean mTracking;

    public KeyEvent(int action, int code) {
        this(System.currentTimeMillis(), System.currentTimeMillis(), action, code, 0);
    }

    public KeyEvent(KeyEvent origEvent) {
        this(origEvent, origEvent == null ? System.currentTimeMillis() : origEvent.getEventTime(),
                origEvent == null ? 0 : origEvent.getRepeatCount());
    }

    public KeyEvent(KeyEvent origEvent, long eventTime, int newRepeat) {
        if (origEvent == null) {
            mDownTime = eventTime;
            mEventTime = eventTime;
            mAction = ACTION_DOWN;
            mKeyCode = 0;
            mRepeatCount = newRepeat;
            mMetaState = 0;
            mScanCode = 0;
            mFlags = 0;
            mDeviceId = 0;
            mSource = 0;
            mCharacters = null;
            return;
        }
        mDownTime = origEvent.mDownTime;
        mEventTime = eventTime;
        mAction = origEvent.mAction;
        mKeyCode = origEvent.mKeyCode;
        mRepeatCount = newRepeat;
        mMetaState = origEvent.mMetaState;
        mScanCode = origEvent.mScanCode;
        mFlags = origEvent.mFlags;
        mDeviceId = origEvent.mDeviceId;
        mSource = origEvent.mSource;
        mCharacters = origEvent.mCharacters;
    }

    public KeyEvent(long downTime, long eventTime, int action, int code) {
        this(downTime, eventTime, action, code, 0);
    }

    public KeyEvent(long downTime, long eventTime, int action, int code, int repeat) {
        this(downTime, eventTime, action, code, repeat, 0);
    }

    public KeyEvent(long downTime, long eventTime, int action, int code, int repeat, int metaState) {
        mDownTime = downTime;
        mEventTime = eventTime;
        mAction = action;
        mKeyCode = code;
        mRepeatCount = repeat;
        mMetaState = metaState;
        mScanCode = 0;
        mFlags = 0;
        mDeviceId = 0;
        mSource = 0;
        mCharacters = null;
    }

    public static KeyEvent changeTimeRepeat(KeyEvent event, long eventTime, int newRepeat) {
        if (event == null) {
            return null;
        }
        return new KeyEvent(event, eventTime, newRepeat);
    }

    public final boolean dispatch(Callback receiver) {
        if (receiver == null) {
            return false;
        }
        switch (mAction) {
            case ACTION_DOWN:
                if (mRepeatCount == 0) {
                    return receiver.onKeyDown(mKeyCode, this);
                }
                return receiver.onKeyMultiple(mKeyCode, mRepeatCount, this);
            case ACTION_UP:
                return receiver.onKeyUp(mKeyCode, this);
            case ACTION_MULTIPLE:
                return receiver.onKeyMultiple(mKeyCode, mRepeatCount, this);
            default:
                return false;
        }
    }

    public final int getAction() {
        return mAction;
    }

    public final int getKeyCode() {
        return mKeyCode;
    }

    public final long getDownTime() {
        return mDownTime;
    }

    public final long getEventTime() {
        return mEventTime;
    }

    public final int getRepeatCount() {
        return mRepeatCount;
    }

    public final int getMetaState() {
        return mMetaState;
    }

    public final int getFlags() {
        return mFlags;
    }

    public final int getScanCode() {
        return mScanCode;
    }

    public final int getDeviceId() {
        return mDeviceId;
    }

    public final int getSource() {
        return mSource;
    }

    public final String getCharacters() {
        return mCharacters;
    }

    public final boolean isCanceled() {
        return (mFlags & FLAG_CANCELED) != 0;
    }

    public final boolean isLongPress() {
        return (mFlags & FLAG_LONG_PRESS) != 0;
    }

    public final boolean isTracking() {
        return mTracking;
    }

    public final void startTracking() {
        mTracking = true;
    }
}
