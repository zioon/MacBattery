// Minimal AppleSMC client (from the reference MacMonitor implementation).
// Uses the exact C struct layout so the 80-byte protocol frame is correct.
#include "SMC.h"
#include <stddef.h>
#include <string.h>

// 整机功率候选键的唯一定义处（SMC.swift 与 MacBatteryHelper/main.swift 均从
// SMCPowerKeyCount() / SMCPowerKey() 读取本表）。顺序即探测优先级：
// 逐个尝试，取首个读到非零值的键。
static const char *const kSMCPowerKeys[] = {
    "PSTR",  // System total power (W)
    "PDTR",  // 一些固件的总功耗
    "PCHC",  // Chip/package power
    "PSYS",  // 部分固件
    "PWRS",
};

int SMCPowerKeyCount(void) {
  return (int)(sizeof(kSMCPowerKeys) / sizeof(kSMCPowerKeys[0]));
}

const char *SMCPowerKey(int index) {
  if (index < 0 || index >= SMCPowerKeyCount()) {
    return NULL;
  }
  return kSMCPowerKeys[index];
}

io_connect_t SMCOpen(void) {
  kern_return_t result;
  io_iterator_t iterator;
  io_object_t device;
  io_connect_t conn = 0;

  CFMutableDictionaryRef matchingDictionary = IOServiceMatching("AppleSMC");
  result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary,
                                        &iterator);
  if (result != kIOReturnSuccess) {
    return 0;
  }

  device = IOIteratorNext(iterator);
  IOObjectRelease(iterator);

  if (device == 0) {
    return 0;
  }

  result = IOServiceOpen(device, mach_task_self(), 0, &conn);
  IOObjectRelease(device);

  if (result != kIOReturnSuccess) {
    return 0;
  }

  return conn;
}

kern_return_t SMCClose(io_connect_t conn) { return IOServiceClose(conn); }

static kern_return_t SMCCall(io_connect_t conn, int index,
                             SMCKeyData_t *inputStructure,
                             SMCKeyData_t *outputStructure) {
  size_t structureInputSize = sizeof(SMCKeyData_t);
  size_t structureOutputSize = sizeof(SMCKeyData_t);

  return IOConnectCallStructMethod(conn, index, inputStructure,
                                   structureInputSize, outputStructure,
                                   &structureOutputSize);
}

kern_return_t SMCReadKey(io_connect_t conn, const char *key,
                         SMCKeyData_t *val) {
  kern_return_t result;
  SMCKeyData_t inputStructure;
  SMCKeyData_t outputStructure;

  memset(&inputStructure, 0, sizeof(SMCKeyData_t));
  memset(&outputStructure, 0, sizeof(SMCKeyData_t));
  memset(val, 0, sizeof(SMCKeyData_t));

  inputStructure.key = (key[0] << 24) | (key[1] << 16) | (key[2] << 8) | key[3];
  inputStructure.data8 = SMC_CMD_READ_KEYINFO;

  result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStructure, &outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }

  val->keyInfo.dataSize = outputStructure.keyInfo.dataSize;
  val->keyInfo.dataType = outputStructure.keyInfo.dataType;
  inputStructure.keyInfo.dataSize = val->keyInfo.dataSize;
  inputStructure.data8 = SMC_CMD_READ_BYTES;

  result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStructure, &outputStructure);
  if (result != kIOReturnSuccess) {
    return result;
  }

  memcpy(val->bytes, outputStructure.bytes, sizeof(outputStructure.bytes));
  return kIOReturnSuccess;
}

double SMCGetFloatValue(io_connect_t conn, const char *key) {
  SMCKeyData_t val;
  kern_return_t result = SMCReadKey(conn, key, &val);
  if (result != kIOReturnSuccess) {
    return 0.0;
  }

  // flt (0x666C7420) — IEEE 754 float, used for power/fan keys
  if (val.keyInfo.dataType == 1718383648) {
    float f;
    memcpy(&f, val.bytes, sizeof(float));
    return (double)f;
  }

  // sp78 (0x73703738) — signed fixed-point 7.8, temperature
  if (val.keyInfo.dataType == 1936734008) {
    int16_t raw =
        (int16_t)(((unsigned char)val.bytes[0] << 8) | (unsigned char)val.bytes[1]);
    return (double)raw / 256.0;
  }

  return 0.0;
}

// ── 充电抑制：键与取值的唯一定义处 ────────────────────────────────────────────

// 充电抑制候选键。CH0B 是主控键；CH0C 在多数机型上需要一并写入才会真正断开充电，
// 因此这里**逐个尝试全部**（而不是命中即止）。两键的语义与取值相同：
//   0x00 = 允许充电，0x02 = 抑制充电。
static const char *const kSMCChargeKeys[] = {
    "CH0B",
    "CH0C",
};

#define SMC_CHARGE_ALLOW_VALUE 0x00
#define SMC_CHARGE_INHIBIT_VALUE 0x02

int SMCChargeKeyCount(void) {
  return (int)(sizeof(kSMCChargeKeys) / sizeof(kSMCChargeKeys[0]));
}

const char *SMCChargeKey(int index) {
  if (index < 0 || index >= SMCChargeKeyCount()) {
    return NULL;
  }
  return kSMCChargeKeys[index];
}

unsigned char SMCChargeAllowValue(void) { return SMC_CHARGE_ALLOW_VALUE; }
unsigned char SMCChargeInhibitValue(void) { return SMC_CHARGE_INHIBIT_VALUE; }

// 「最大充电量」键。取值是百分数（0…100），不是开关值 —— 因此它**不**进 kSMCChargeKeys：
// 那一组的判定是「值 ∈ {0x00, 0x02}」，套在 BCLM 上会把 0x00/0x02 误当成"允许/抑制"，
// 而它们在这里只代表 0% / 2%。两套机制必须分开走各自的取值校验。
const char *SMCChargeMaxLevelKey(void) { return "BCLM"; }

// 额外「只读探测」候选键。这些名字在公开实现里作为充电控制键出现过，但语义未经确认，
// 因此**只读不写**：它们只用来回答"这台机器有哪些相关键"，不参与任何执行判定。
// 顺序即输出顺序（App 会把它们拼成一行诊断信息）。
// ⚠️ BCLM 刻意**不在**这里：它已是可写的正式机制（见上面的 SMCChargeMaxLevelKey），
// helper 会显式探测它，放在这里只会让同一个键报两遍。
static const char *const kSMCChargeProbeKeys[] = {
    "CHTE",  // 部分新机型上的充电终止键
    "CH0I",  // AlDente 等实现提到过的一组
    "CH0J",
    "CH0K",
    "ACEN",  // AC 使能类
    "CHWA",
};

int SMCChargeProbeKeyCount(void) {
  return (int)(sizeof(kSMCChargeProbeKeys) / sizeof(kSMCChargeProbeKeys[0]));
}

const char *SMCChargeProbeKey(int index) {
  if (index < 0 || index >= SMCChargeProbeKeyCount()) {
    return NULL;
  }
  return kSMCChargeProbeKeys[index];
}

// ── 单字节读写 ──────────────────────────────────────────────────────────────

// 把 4 字符键名打包成 SMC 协议里的 32 位整数。
// 逐字节显式转 unsigned char：键名是 ASCII，但 char 在本平台是有符号的，
// 直接左移在遇到非 ASCII 字节时会产生符号扩展（现有 SMCReadKey 用的就是直接左移，
// 这里不再沿用，避免把这类边界带进新代码）。
static unsigned int SMCKeyToUInt32(const char *key) {
  return ((unsigned int)(unsigned char)key[0] << 24) |
         ((unsigned int)(unsigned char)key[1] << 16) |
         ((unsigned int)(unsigned char)key[2] << 8) |
         ((unsigned int)(unsigned char)key[3]);
}

// 只读探测：键是否存在 / dataSize / 首字节取值。
// 不存在或读失败时把出参写成"空"（0 / -1），而不是留着上一次的值 —— 调用方据此区分
// 「键存在但值是 0」与「键不存在」，把两者混起来正是这次要修的缺陷。
int SMCProbeKey(io_connect_t conn, const char *key, unsigned int *outDataSize,
                int *outValue) {
  SMCKeyData_t val;
  if (SMCReadKey(conn, key, &val) != kIOReturnSuccess) {
    if (outDataSize) {
      *outDataSize = 0;
    }
    if (outValue) {
      *outValue = -1;
    }
    return 0;
  }
  if (outDataSize) {
    *outDataSize = val.keyInfo.dataSize;
  }
  if (outValue) {
    *outValue =
        val.keyInfo.dataSize >= 1 ? (int)(unsigned char)val.bytes[0] : -1;
  }
  return 1;
}

// ── 键名枚举（只读） ────────────────────────────────────────────────────────

int SMCKeyCount(io_connect_t conn, unsigned int *outCount) {
  SMCKeyData_t val;
  // "#KEY" 是 SMC 的特殊键，其 ui32 值即键总数。
  if (SMCReadKey(conn, "#KEY", &val) != kIOReturnSuccess) {
    return 0;
  }
  if (val.keyInfo.dataSize != 4) {
    return 0;
  }
  unsigned int n = ((unsigned int)(unsigned char)val.bytes[0] << 24) |
                   ((unsigned int)(unsigned char)val.bytes[1] << 16) |
                   ((unsigned int)(unsigned char)val.bytes[2] << 8) |
                   ((unsigned int)(unsigned char)val.bytes[3]);
  // 上限守卫：读到的若是垃圾（几百万），上层会拿着它遍历一整天。
  if (n == 0 || n > 100000) {
    return 0;
  }
  if (outCount) {
    *outCount = n;
  }
  return 1;
}

int SMCKeyNameAtIndex(io_connect_t conn, unsigned int index, char *outKey) {
  SMCKeyData_t inputStructure;
  SMCKeyData_t outputStructure;

  memset(&inputStructure, 0, sizeof(SMCKeyData_t));
  memset(&outputStructure, 0, sizeof(SMCKeyData_t));

  inputStructure.data8 = SMC_CMD_READ_INDEX;
  inputStructure.data32 = index;
  if (SMCCall(conn, KERNEL_INDEX_SMC, &inputStructure, &outputStructure) !=
      kIOReturnSuccess) {
    return 0;
  }

  // 键名按"首字符在高位"打包 —— 与 SMCReadKey 里 `inputStructure.key` 的打包顺序一致
  // （同一套字节序，不引入第二种约定）。
  unsigned int packed = outputStructure.key;
  char name[4];
  name[0] = (char)((packed >> 24) & 0xFF);
  name[1] = (char)((packed >> 16) & 0xFF);
  name[2] = (char)((packed >> 8) & 0xFF);
  name[3] = (char)(packed & 0xFF);

  // 只接受 4 个可打印 ASCII。字节序万一理解反了，这里会挡掉一批乱码；
  // 剩下的顺序问题由调用方用"按名读一次"自校验（见 MacBatteryHelper）。
  for (int i = 0; i < 4; i++) {
    unsigned char c = (unsigned char)name[i];
    if (c < 0x20 || c > 0x7E) {
      return 0;
    }
  }

  if (outKey) {
    memcpy(outKey, name, 4);
    outKey[4] = '\0';
  }
  return 1;
}

int SMCReadByte(io_connect_t conn, const char *key, unsigned char *outValue) {
  SMCKeyData_t val;
  if (SMCReadKey(conn, key, &val) != kIOReturnSuccess) {
    return 0;  // 键不存在（机型不支持）
  }
  if (val.keyInfo.dataSize < 1) {
    return 0;  // 键存在但没有数据，按不可用处理
  }
  *outValue = (unsigned char)val.bytes[0];
  return 1;
}

int SMCWriteByte(io_connect_t conn, const char *key, unsigned char value) {
  SMCKeyData_t inputStructure;
  SMCKeyData_t outputStructure;

  memset(&inputStructure, 0, sizeof(SMCKeyData_t));
  memset(&outputStructure, 0, sizeof(SMCKeyData_t));

  // ① 先取 keyInfo：写数据前必须先知道该键的 dataSize，协议帧里要回填。
  inputStructure.key = SMCKeyToUInt32(key);
  inputStructure.data8 = SMC_CMD_READ_KEYINFO;

  kern_return_t result =
      SMCCall(conn, KERNEL_INDEX_SMC, &inputStructure, &outputStructure);
  if (result != kIOReturnSuccess) {
    return 0;
  }

  // ② 只往「单字节」键写。
  // 这是本函数唯一的硬性守卫：如果该键的 dataSize 不是 1，说明它不是我们认知里的
  // 开关量（可能是个多字节的结构体），按 1 字节硬写会把它其余字节留成未定义值 ——
  // 那是在写一块我们并不理解、且直接影响电源管理的寄存器。宁可判为不支持。
  if (outputStructure.keyInfo.dataSize != 1) {
    return 0;
  }

  inputStructure.keyInfo.dataSize = outputStructure.keyInfo.dataSize;
  inputStructure.data8 = SMC_CMD_WRITE_BYTES;
  inputStructure.bytes[0] = (char)value;

  result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStructure, &outputStructure);
  return result == kIOReturnSuccess ? 1 : 0;
}