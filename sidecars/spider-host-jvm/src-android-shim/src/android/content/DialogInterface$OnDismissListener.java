package android.content;

/**
 * android.content.DialogInterface$OnDismissListener 的垫片：按 AOSP 公开签名声明
 * {@code void onDismiss(DialogInterface dialog)}。
 *
 * <p>参数类型用本 shim 的 {@link DialogInterface}，签名完整，不含 UI 类型。
 *
 * <p>代价：**能加载 ≠ 行为完整**。桌面端没有 Dialog，这个回调**永远不会被调用**；它只是让实现它的
 * 站源类（com.github.catvod.spider.c/g 等）能加载。站源依赖「对话框关闭后继续」的逻辑在桌面端
 * 不会前进，调用方应如实上报缺失，而不是把「类加载成功」当成功能可用。
 *
 * <p>为什么是顶层类而不是 DialogInterface 的嵌套类：见
 * {@link DialogInterface$OnCancelListener} 的同段说明（批次文件清单 + 二进制名不变）。
 */
public interface DialogInterface$OnDismissListener {

    void onDismiss(DialogInterface dialog);
}
