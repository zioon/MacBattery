#!/bin/bash
# 一次性安装 MacBattery 的 root helper（用于读取真实整机功耗）。
# 用法：在项目根目录执行  sudo ./Scripts/install_helper.sh
set -e
cd "$(dirname "$0")/.."

echo "== 编译 root helper =="
swift build -c release --target MacBatteryHelper

BIN=".build/release/MacBatteryHelper"
DEST="/Library/PrivilegedHelperTools/macbattery-helper"
PLIST="/Library/LaunchDaemons/com.zioon.macbattery.helper.plist"

echo "== 写入 /Library（需要输入密码） =="
sudo mkdir -p /Library/PrivilegedHelperTools
sudo cp "$BIN" "$DEST"
sudo chown root:wheel "$DEST"
sudo chmod 755 "$DEST"

sudo tee "$PLIST" >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.zioon.macbattery.helper</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Library/PrivilegedHelperTools/macbattery-helper</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/macbattery-helper.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/macbattery-helper.log</string>
</dict>
</plist>
EOF

sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"

# 重载守护（兼容新/老 launchctl）
sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST" 2>/dev/null || sudo launchctl load "$PLIST"

echo ""
echo "== 完成 =="
echo "root helper 已启动：/Library/PrivilegedHelperTools/macbattery-helper"
echo "验证（应输出系统整机功率）：cat /tmp/macbattery_power.json"