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