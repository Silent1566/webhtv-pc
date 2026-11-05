package android.database.sqlite;

/**
 * android.database.sqlite.SQLiteClosable 的垫片抽象类。
 *
 * <p>真机上这是一个**引用计数**基类：acquireReference 加一，releaseReference 减一，
 * 归零时回调 onAllReferencesReleased() 真正释放原生句柄。站源里常见
 * {@code try { db.acquireReference(); ... } finally { db.releaseReference(); }}
 * 的写法，所以计数语义必须保留——写成空操作会让 releaseReference 提前触发关闭，
 * 或让引用永不归零。
 */
public abstract class SQLiteClosable implements java.io.Closeable {

    private int referenceCount = 1;

    public SQLiteClosable() {
        // 默认持有 1 个引用（创建即持有），与真机一致。
    }

    public void acquireReference() {
        synchronized (this) {
            if (referenceCount <= 0) {
                throw new IllegalStateException(
                        "attempt to re-open an already-closed object: " + this);
            }
            referenceCount++;
        }
    }

    public void releaseReference() {
        boolean released;
        synchronized (this) {
            referenceCount--;
            released = referenceCount == 0;
        }
        if (released) {
            onAllReferencesReleased();
        }
    }

    public void releaseReferenceFromContainer() {
        // 容器（CursorWindow 等）持有的引用释放路径；桌面没有容器层，语义合并到 releaseReference。
        releaseReference();
    }

    protected abstract void onAllReferencesReleased();

    protected void onAllReferencesReleasedFromContainer() {
        // 真机上与 onAllReferencesReleased 分开；垫片里容器路径不存在，交给子类决定是否覆盖。
        onAllReferencesReleased();
    }

    public void close() {
        // java.io.Closeable 的入口：等价于释放一个引用。
        releaseReference();
    }
}
