# Flutter相关
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# 权限处理器
-keep class com.baseflow.permissionhandler.** { *; }

# 蓝牙相关
-keep class com.boskokg.flutter_blue_plus.** { *; }

# 保持所有native方法
-keepclasseswithmembernames class * {
    native <methods>;
}

# 保持所有枚举
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# 保持Parcelable
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}

# 解决Google Play Core缺失类的问题
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

# 或者更简单的方式，直接忽略这些警告
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# 保持Flutter相关的所有类
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.embedding.android.** { *; }
-keep class io.flutter.embedding.engine.** { *; }

# 保持你的自定义插件
-keep class com.example.orbitz.** { *; }

# 保持所有Serializable类
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# 保持所有Exception类
-keep public class * extends java.lang.Exception

# 保持所有R类
-keepclassmembers class **.R$* {
    public static <fields>;
}