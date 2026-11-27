"""Patch the generated AndroidManifest/MainActivity for background audio + LAN HTTP."""
import re
from pathlib import Path

root = Path("android/app/src/main")
m = root / "AndroidManifest.xml"
x = m.read_text()

perms = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
"""
if "FOREGROUND_SERVICE_MEDIA_PLAYBACK" not in x:
    x = x.replace("<application", perms + "    <application", 1)
x = x.replace("<application", '<application android:usesCleartextTraffic="true"', 1) \
    if "usesCleartextTraffic" not in x else x

services = """        <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback" android:exported="true">
            <intent-filter><action android:name="android.media.browse.MediaBrowserService"/></intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver" android:exported="true">
            <intent-filter><action android:name="android.intent.action.MEDIA_BUTTON"/></intent-filter>
        </receiver>
"""
if "AudioService" not in x:
    x = x.replace("</application>", services + "    </application>", 1)
m.write_text(x)

# audio_service needs an AudioServiceActivity
for f in root.rglob("MainActivity.kt"):
    s = f.read_text()
    s = s.replace("import io.flutter.embedding.android.FlutterActivity",
                  "import com.ryanheise.audioservice.AudioServiceActivity")
    s = s.replace(": FlutterActivity()", ": AudioServiceActivity()")
    f.write_text(s)
# Some plugins (file_picker etc.) are compiled against android-34 but a dependency
# needs 36+. Force compileSdk 36 on every module. Must be PREPENDED so the
# afterEvaluate hooks register before projects are evaluated.
for name in ("build.gradle.kts", "build.gradle"):
    g = Path("android") / name
    if g.exists():
        txt = g.read_text()
        if "FOLIO_COMPILE_SDK" not in txt:
            if name.endswith(".kts"):
                hook = '''// FOLIO_COMPILE_SDK
subprojects {
    afterEvaluate {
        val ext = project.extensions.findByName("android")
        if (ext != null) {
            for (m in listOf("setCompileSdkVersion", "compileSdkVersion")) {
                try {
                    ext.javaClass.getMethod(m, Int::class.javaPrimitiveType).invoke(ext, 36)
                    break
                } catch (e: Exception) { }
            }
        }
    }
}

'''
            else:
                hook = '''// FOLIO_COMPILE_SDK
subprojects {
    afterEvaluate { p ->
        if (p.hasProperty("android")) { p.android.compileSdkVersion 36 }
    }
}

'''
            g.write_text(hook + txt)
        break
print("Android manifest + compileSdk patched")
