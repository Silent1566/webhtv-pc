#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PROJECT="$ROOT/prototypes/compose_libmpv"
MPV_LIB="$ROOT/.local/mpv/usr/lib/x86_64-linux-gnu"
GSON_JAR=${GSON_JAR:-$(find /home/maple/.gradle/caches/modules-2/files-2.1/com.google.code.gson/gson -type f -name 'gson-*.jar' -print 2>/dev/null | sort -V | tail -1)}
"$PROJECT/scripts/build_debug.sh"
LD_LIBRARY_PATH="$MPV_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
java -Djava.library.path="$PROJECT/build/debug/native" -cp "$PROJECT/build/debug/classes:$GSON_JAR" local.webhtv.phase0.Main "$@"
