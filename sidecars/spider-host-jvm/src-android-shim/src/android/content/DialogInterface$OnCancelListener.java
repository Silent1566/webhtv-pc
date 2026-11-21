package android.content;

/**
 * android.content.DialogInterface$OnCancelListener 的垫片：按 AOSP 公开签名声明
 * {@code void onCancel(DialogInterface dialog)}。
 *
 * <p>参数类型用本 shim 的 {@link DialogInterface}（同包、声明面一致），不需要 UI 类型，所以这个
 * 接口能给出**完整签名**而不是退化成空接口。
 *
 * <p>代价：**能加载 ≠ 行为完整**。桌面端没有 Dialog，这个回调**永远不会被调用**；它存在的意义
 * 只是让实现它的站源类（com.github.catvod.spider.b/e 等）能加载并被实例化。站源把「用户取消」
 * 当作控制流时，桌面端不会走到那条分支，调用方应如实上报，不要静默当成成功。
 *
 * <p>为什么是顶层类而不是 DialogInterface 的嵌套类：批次文件清单要求每个垫片类各占一个源文件，
 * {@code $} 在 Java 标识符里合法，顶层类名 {@code DialogInterface$OnCancelListener} 产出的二进制名
 * 仍是 android/content/DialogInterface$OnCancelListener.class（同 android/graphics/Bitmap$Config）。
 */
public interface DialogInterface$OnCancelListener {

    void onCancel(DialogInterface dialog);
}
