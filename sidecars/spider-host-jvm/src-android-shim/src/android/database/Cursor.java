package android.database;

/**
 * android.database.Cursor 的垫片接口。
 *
 * <p>只声明签名，不写实现：真机上 Cursor 由 SQLiteCursor / MatrixCursor /
 * AbstractCursor 等具体类实现，垫片侧若在这里塞默认实现，会把「谁负责实现」
 * 的边界搅乱，也让后续接真实 ResultSet 的批次没法覆盖。
 *
 * <p>成员严格取自 android-36 android.jar 的 javap 输出；仅省略了那些签名依赖
 * 仓库中尚缺类型的成员（见文件末尾登记）。
 */
public interface Cursor extends java.io.Closeable {

    public static final int FIELD_TYPE_NULL = 0;
    public static final int FIELD_TYPE_INTEGER = 1;
    public static final int FIELD_TYPE_FLOAT = 2;
    public static final int FIELD_TYPE_STRING = 3;
    public static final int FIELD_TYPE_BLOB = 4;

    int getCount();

    int getPosition();

    boolean moveToFirst();

    boolean moveToNext();

    boolean moveToPrevious();

    boolean moveToPosition(int position);

    boolean moveToLast();

    boolean move(int offset);

    boolean isFirst();

    boolean isLast();

    boolean isBeforeFirst();

    boolean isAfterLast();

    int getColumnCount();

    int getColumnIndex(String columnName);

    int getColumnIndexOrThrow(String columnName) throws IllegalArgumentException;

    String getColumnName(int columnIndex);

    String[] getColumnNames();

    String getString(int columnIndex);

    int getInt(int columnIndex);

    long getLong(int columnIndex);

    short getShort(int columnIndex);

    float getFloat(int columnIndex);

    double getDouble(int columnIndex);

    byte[] getBlob(int columnIndex);

    boolean isNull(int columnIndex);

    int getType(int columnIndex);

    boolean getWantsAllOnMoveCalls();

    void close();

    boolean isClosed();

    // ---- 未声明成员（签名依赖仓库中尚缺的类型）： ----
    // void copyStringToBuffer(int, android.database.CharArrayBuffer)
    // void deactivate()                                  -> 可补，但属 AbstractCursor 语义，暂缓
    // android.os.Bundle getExtras() / respond / setExtras -> android.os.Bundle 需补
    // android.net.Uri getNotificationUri() / setNotificationUri(...) -> android.net.Uri、android.content.ContentResolver 需补
    // void registerContentObserver(android.database.ContentObserver)  -> 需补
    // void registerDataSetObserver(android.database.DataSetObserver)  -> 需补
    // boolean requery()
}
