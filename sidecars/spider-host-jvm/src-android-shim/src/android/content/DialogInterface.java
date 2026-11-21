package android.content;

/**
 * android.content.DialogInterface 的垫片（AOSP 也是 interface）：只声明**不碰 UI 的成员**。
 *
 * <p>为什么需要它：站源里有一批匿名类实现 {@code DialogInterface$OnCancelListener} /
 * {@code DialogInterface$OnDismissListener}（反混淆后是 com.github.catvod.spider.b/c/e/g），
 * 而这两个接口的 {@code onCancel(DialogInterface)} / {@code onDismiss(DialogInterface)}
 * 以 DialogInterface 本身为参数类型——DialogInterface 缺席时，
 * 那些类在加载期即 NoClassDefFoundError。
 *
 * <p>代价：**能加载 ≠ 行为完整**。桌面端没有 Dialog，也不会弹窗；这里的 cancel()/dismiss()
 * 只是给站源一个签名与 AOSP 一致的方法描述符，站源调它不会有任何 UI 效果。站源若依赖
 * 「用户点了取消/关闭」这一真实交互，桌面端必须如实上报为不可用，不能当成静默成功。
 *
 * <p>刻意不声明（本批次边界外，登记以免下次重查）：
 * <ul>
 *   <li>{@code OnKeyListener.onKey(DialogInterface, int, KeyEvent)} —— 需要本 shim 已有的
 *       {@code android.view.KeyEvent}，但不在本批次文件清单内；</li>
 *   <li>{@code OnClickListener} / {@code OnMultiChoiceClickListener} / {@code OnShowListener}
 *       —— 分别需要 {@code android.content.DialogInterface} 自身以外的类型与 Widget 语义；</li>
 *   <li>{@code OnCancelListener}/{@code OnDismissListener} **不在本文件内声明**：批次文件清单要求
 *       每个垫片类各占一个源文件，二者以同包顶层类 {@code DialogInterface$OnCancelListener} /
 *       {@code DialogInterface$OnDismissListener} 提供，二进制名与 AOSP 的嵌套接口完全一致
 *       （同 android/graphics/Bitmap$Config 的做法）；代价是**源码里写不了**
 *       {@code DialogInterface.OnCancelListener}，只有字节码链接能找到它们——而垫片的用途正是后者。</li>
 * </ul>
 */
public interface DialogInterface {

    // 取值照 AOSP：按钮回调 onCancel/DialogInterface 的常用标识。
    int BUTTON_POSITIVE = -1;
    int BUTTON_NEGATIVE = -2;
    int BUTTON_NEUTRAL = -3;

    /** 相当于用户按了「取消」；桌面端无 UI，调用方实现自行决定语义。 */
    void cancel();

    /** 关闭对话框；桌面端无 UI，同上。 */
    void dismiss();
}
