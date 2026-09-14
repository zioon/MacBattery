#!/bin/bash
# 安装 MacBattery 的 root helper（用于读取真实整机功耗）。
#
# 用法：进入【包含 install_helper.sh 和 macbattery-helper 的目录】（如 DMG 挂载点），
#       执行：
#           sudo ./install_helper.sh
#       或（若无执行权限）：
#           sudo bash ./install_helper.sh
#
# 说明：本脚本直接使用同目录下的 macbattery-helper 二进制，无需编译。
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/macbattery-helper"
DEST="/Library/PrivilegedHelperTools/macbattery-helper"
PLIST="/Library/LaunchDaemons/com.zioon.macbattery.helper.plist"

if [ ! -f "$BIN" ]; then
  echo "错误：未在当前目录找到 $BIN"
  echo "请先 cd 到同时包含 install_helper.sh 和 macbattery-helper 的目录再运行。"
  exit 1
fi

echo "== 写入系统目录（需要输入密码） =="
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
	<key>StandardErrPath</key>
	<string>/tmp/macbattery-helper.log</string>
</dict>
</plist>
EOF

sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"

# 重载守护（兼容新/老 launchctl）
sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST" 2>/dev/null || sudo launchctl load "$PLIST"

sleep 2
echo ""
echo "== 完成 =="
echo "root helper 已启动：/Library/PrivilegedHelperTools/macbattery-helper"
echo "验证（应输出系统整机功率）：cat /tmp/macbattery_power.json"