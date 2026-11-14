#!/usr/bin/env bash
# Builds galaxy-live.apk without Gradle: aapt2, javac, d8, zipalign, apksigner.
#
#   ANDROID_HOME=~/android-sdk PHONE_KEY=<the Worker's PHONE_KEY> ./build.sh
#
# Needs a JDK and, in the SDK, "build-tools;35.0.0" and "platforms;android-34".
# RELAY_HOST: the relay Worker's host. KEYSTORE: the signing key, made on the first run;
# keep it, Android installs an update only when it is signed by the same key.
set -euo pipefail
cd "$(dirname "$0")"
SDK=${ANDROID_HOME:?set ANDROID_HOME}
BT=$SDK/build-tools/${BUILD_TOOLS:-35.0.0}
JAR=$SDK/platforms/android-34/android.jar
: "${PHONE_KEY:?set PHONE_KEY}"
HOST=${RELAY_HOST:-galaxy-live-relay.theo-b59.workers.dev}
KS=${KEYSTORE:-$HOME/.android/galaxy-live.jks}
VERSION=${VERSION:-1}

rm -rf build && mkdir -p build/gen/live/galaxy/relay build/classes build/dex
cat > build/gen/live/galaxy/relay/Config.java <<JAVA
package live.galaxy.relay;
final class Config {
    static final String HOST = "$HOST";
    static final String KEY = "$PHONE_KEY";
}
JAVA

"$BT/aapt2" compile --dir res -o build/res.zip
"$BT/aapt2" link -o build/base.apk -I "$JAR" --manifest AndroidManifest.xml -R build/res.zip \
  --min-sdk-version 26 --target-sdk-version 34 --version-code "$VERSION" --version-name "1.$((VERSION - 1))" --auto-add-overlay
# Java 8 APIs from the JDK (lambdas need its LambdaMetafactory), Android's from android.jar; d8 desugars.
javac -nowarn -Xlint:-options -encoding UTF-8 --release 8 -classpath "$JAR" -d build/classes \
  src/live/galaxy/relay/*.java build/gen/live/galaxy/relay/Config.java
"$BT/d8" --release --min-api 26 --lib "$JAR" --output build/dex $(find build/classes -name '*.class')
cp build/base.apk build/unsigned.apk
(cd build/dex && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f -p 4 build/unsigned.apk build/aligned.apk
if [ ! -f "$KS" ]; then
  mkdir -p "$(dirname "$KS")"
  keytool -genkeypair -keystore "$KS" -storepass REDACTED -keypass REDACTED -alias galaxy-live \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Galaxy Live" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:REDACTED --key-pass pass:REDACTED --out build/galaxy-live.apk build/aligned.apk
"$BT/apksigner" verify build/galaxy-live.apk
ls -l build/galaxy-live.apk
