import Foundation
import Darwin
import SMCBridge

// MacBattery root helper：
// 以 root 通过 launchd 守护常驻，每秒读一次 SMC 整机功耗（PSTR 等），
// 写到全局可读的 /tmp/macbattery_power.json，供无权限的 GUI app 读取真实整机功率。
// 安装方式见 Scripts/install_helper.sh（一次性 sudo）。

let outputPath = "/tmp/macbattery_power.json"
let interval: UInt32 = 1  // 秒

// 优雅停机：捕获 SIGTERM / SIGINT 退出，便于 launchd 重启。
signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

// 主循环
while true {
    let watts = readSystemPowerWatts()
    writePower(watts)
    sleep(interval)
}

// MARK: - SMC 读取

func readSystemPowerWatts() -> Double {
    let conn = SMCOpen()
    guard conn != 0 else { return 0 }
    defer { SMCClose(conn) }

    for key in ["PSTR", "PDTR", "PCHC", "PSYS", "PWRS"] {
        let v = SMCGetFloatValue(conn, key)
        if v > 0, v.isFinite {
            return v
        }
    }
    return 0
}

// MARK: - 写入

func writePower(_ watts: Double) {
    let payload = "{\"systemPower\":\(watts)}"
    do {
        try payload.write(toFile: outputPath, atomically: true, encoding: .utf8)
    } catch {
        // 忽略；下次循环重试
    }
    let dc = outputPath.withCString { pathCstr in
        Darwin.chmod(pathCstr, 0644)
    }
}