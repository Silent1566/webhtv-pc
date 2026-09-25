#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PROJECT="$ROOT/prototypes/compose_libmpv"
JAVA_HOME=${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}
MPV_ROOT="$ROOT/.local/mpv/usr"
MPV_LIB="$MPV_ROOT/lib/x86_64-linux-gnu"
BUILD="$PROJECT/build/debug"
GSON_JAR=${GSON_JAR:-$(find /home/maple/.gradle/caches/modules-2/files-2.1/com.google.code.gson/gson -type f -name 'gson-*.jar' -print 2>/dev/null | sort -V | tail -1)}
if test -z "$GSON_JAR"; then
  echo "错误：未找到 Gson JAR，无法构建 HTTP API 闭环原型。" >&2
  exit 2
fi
mkdir -p "$BUILD/classes" "$BUILD/native"
javac -encoding UTF-8 -cp "$GSON_JAR" -d "$BUILD/classes" $(find "$PROJECT/src/main/java" -name '*.java' -print)
gcc -std=c17 -Wall -Wextra -Werror -fPIC -shared \
  -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" -I"$MPV_ROOT/include" \
  "$PROJECT/src/main/c/webhtv_mpv_jni.c" -L"$MPV_LIB" -Wl,-rpath,"$MPV_LIB" -lmpv \
  -o "$BUILD/native/libwebhtv_mpv_jni.so"
echo "Debug prototype built at $BUILD"
