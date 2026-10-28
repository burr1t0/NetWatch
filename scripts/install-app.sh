#!/bin/bash
# Builds NetWatch.app (host app + widget extension) and installs it into ~/Applications.
# The agent (scripts/install.sh) collects the data; this app makes the widget show it live.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR="$HOME/Applications"

# The signing team comes from the Apple Development certificate in the keychain, so no personal ID lives in the repo.
# Override with NETWATCH_TEAM=<Team ID> if you have several certificates.
TEAM="${NETWATCH_TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' | head -1)}"
if [[ -z "$TEAM" ]]; then
    echo "Не найден сертификат Apple Development. Войдите в Xcode с Apple ID или задайте NETWATCH_TEAM=<Team ID>." >&2
    exit 1
fi

xcodegen generate
mkdir -p build
if ! xcodebuild -project NetWatch.xcodeproj -scheme NetWatch -configuration Release \
    -derivedDataPath build/xcode -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" build > build/xcodebuild.log 2>&1; then
    grep -E "error:" build/xcodebuild.log | head -10 >&2
    echo "Сборка не удалась, полный лог: build/xcodebuild.log" >&2
    exit 1
fi
tail -1 build/xcodebuild.log

pkill -x NetWatch 2>/dev/null || true
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/NetWatch.app"
cp -R build/xcode/Build/Products/Release/NetWatch.app "$APP_DIR/"

# Make LaunchServices / PlugInKit notice the widget right away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR/NetWatch.app"
open "$APP_DIR/NetWatch.app"
echo "Готово: $APP_DIR/NetWatch.app"
