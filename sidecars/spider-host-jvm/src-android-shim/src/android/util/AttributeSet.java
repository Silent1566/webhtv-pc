package android.util;

/**
 * android.util.AttributeSet 接口垫片。
 * View / ViewGroup 等构造器签名依赖它，缺该类时整批 android.view 编译失败；
 * 这里只声明接口成员，不提供实现——宿主侧没有 XML 属性来源。
 */
public interface AttributeSet {

    int getAttributeCount();

    String getAttributeName(int index);

    String getAttributeValue(int index);

    String getAttributeValue(String namespace, String name);

    String getAttributeNamespace(int index);

    int getAttributeNameResource(int index);

    int getAttributeListValue(String namespace, String attribute, String[] options, int defaultValue);

    int getAttributeListValue(int index, String[] options, int defaultValue);

    boolean getAttributeBooleanValue(String namespace, String attribute, boolean defaultValue);

    boolean getAttributeBooleanValue(int resourceId, boolean defaultValue);

    int getAttributeResourceValue(String namespace, String attribute, int defaultValue);

    int getAttributeResourceValue(int resourceId, int defaultValue);

    int getAttributeIntValue(String namespace, String attribute, int defaultValue);

    int getAttributeIntValue(int index, int defaultValue);

    int getAttributeUnsignedIntValue(String namespace, String attribute, int defaultValue);

    int getAttributeUnsignedIntValue(int index, int defaultValue);

    float getAttributeFloatValue(String namespace, String attribute, float defaultValue);

    float getAttributeFloatValue(int index, float defaultValue);

    String getIdAttribute();

    int getIdAttributeResourceValue(int defaultValue);

    int getStyleAttribute();

    String getClassAttribute();

    String getPositionDescription();
}
