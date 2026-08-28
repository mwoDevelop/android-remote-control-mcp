# The host application owns its R8 policy. Shizuku API consumer rules are merged transitively.

# Shizuku creates this user service by class name in a shell-UID app_process.
-keep class com.mwodevelop.androidremotecontrol.shizukuadmin.RemoteInputUserService {
    public <init>();
    public <init>(android.content.Context);
}
