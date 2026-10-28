#!/bin/bash
# Builds netwatchd in release mode, installs it and registers a per-user LaunchAgent that starts at login.
#   scripts/install.sh            install / update
#   scripts/install.sh uninstall  remove the agent and the binary (the sample log is kept)
set -euo pipefail

LABEL="com.egor.netwatchd"
BIN_DIR="$HOME/Library/Application Support/NetWatch/bin"
BIN="$BIN_DIR/netwatchd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/NetWatch"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "uninstall" ]]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$BIN"
    echo "Удалено. Лог замеров сохранён в ~/Library/Application Support/NetWatch"
    exit 0
fi

cd "$(dirname "$0")/.."
swift build -c release
mkdir -p "$BIN_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Stop the old copy first so the binary can be replaced.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
cp .build/release/netwatchd "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityBackgroundIO</key><true/>
    <key>StandardOutPath</key><string>$LOG_DIR/netwatchd.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/netwatchd.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Установлено: $BIN"
echo "Агент запущен и стартует при входе в систему. Отчёт: \"$BIN\" report --hours 24"
