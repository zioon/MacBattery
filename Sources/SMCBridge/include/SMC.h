#ifndef SMC_H
#define SMC_H

#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2

#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9
#define SMC_CMD_READ_PLIMIT 11
#define SMC_CMD_READ_VERS 12

typedef struct {
  char major;
  char minor;
  char build;
  char reserved[1];
  unsigned short release;
} SMCKeyData_vers_t;

typedef struct {
  unsigned short version;
  unsigned short length;
  unsigned int cpuPLimit;
  unsigned int gpuPLimit;
  unsigned int memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
  unsigned int dataSize;
  unsigned int dataType;
  char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef char SMCBytes_t[32];

typedef struct {
  unsigned int key;
  SMCKeyData_vers_t vers;
  SMCKeyData_pLimitData_t pLimitData;
  SMCKeyData_keyInfo_t keyInfo;
  char result;
  char status;
  char data8;
  unsigned int data32;
  SMCBytes_t bytes;
} SMCKeyData_t;

typedef char SMCKey_t[5];

typedef struct {
  char key[4];
  SMCKeyData_t data;
} SMCVal_t;

// Function prototypes
io_connect_t SMCOpen(void);
kern_return_t SMCClose(io_connect_t conn);
kern_return_t SMCReadKey(io_connect_t conn, const char *key, SMCKeyData_t *val);
double SMCGetFloatValue(io_connect_t conn, const char *key);

// 单字节键的读 / 写（充电抑制用）。
//
// 返回 int 而不是 kern_return_t，是为了把「成功与否」的判断收敛在 C 侧：
// Swift 侧只需 `if SMCWriteByte(...) == 1`，不必依赖 IOKit 宏在 Swift 里的导入形态。
// 两者都返回 1 表示成功、0 表示失败。
//
// 写入失败的情形包括：键不存在（不是所有机型都有充电抑制键）、该键的 dataSize 不是 1
//（说明它不是我们认知里的开关量，拒绝按 1 字节硬写，以免污染其余字节）。
int SMCReadByte(io_connect_t conn, const char *key, unsigned char *outValue);
int SMCWriteByte(io_connect_t conn, const char *key, unsigned char value);

// 充电抑制键的唯一定义处（helper 从 SMCChargeKey 逐个取，不再各自写一份）。
// 顺序即尝试顺序：**逐个尝试**所有存在的键，而不是找到第一个就停 ——
// 部分机型两个键都要写才会真正断开充电。
int SMCChargeKeyCount(void);
// 返回第 index 个充电抑制键（以 NUL 结尾的只读字符串）；index 越界时返回 NULL。
const char *SMCChargeKey(int index);

// 充电抑制取值的唯一定义处（0x00 = 允许充电，0x02 = 抑制充电）。
// helper 只允许写这两个值之一；读到其它值时不认识的键会被跳过（见 SMC.c 的说明）。
unsigned char SMCChargeAllowValue(void);
unsigned char SMCChargeInhibitValue(void);

// 只读探测（**永不写入**）：把键是否存在、dataSize、首字节取值带回去。
// 返回 1 表示键存在（出参有效）；0 表示键不存在（出参被置为 0 / -1）。
// 这是排查「本机不支持」的唯一手段 —— 用户机器上到底有没有这些键，只有这里能看出来。
int SMCProbeKey(io_connect_t conn, const char *key, unsigned int *outDataSize, int *outValue);

// ── 键名枚举（只读） ────────────────────────────────────────────────────────
// 用来回答"这台机器到底有哪些充电相关键"。候选键名是猜的，枚举出来的是事实 ——
// 机型之间键名并不统一，靠猜键名会一轮一轮地卡住（每轮都要用户重装一次 helper）。
//
// 读取 SMC 键总数（特殊键 "#KEY"，ui32）。成功返回 1；数量明显不合理时返回 0。
int SMCKeyCount(io_connect_t conn, unsigned int *outCount);

// 按索引取键名（SMC_CMD_READ_INDEX），写入 outKey（至少 5 字节，含结尾 NUL）。
// 成功返回 1；键名含不可打印字符时返回 0（宁可丢掉，也不把乱码当键名上报）。
int SMCKeyNameAtIndex(io_connect_t conn, unsigned int index, char *outKey);

// 额外「只读探测」候选键的唯一定义处。
// 这些名字在公开实现里作为充电控制键出现过，但**语义未经确认**，因此只读探测、永不写入。
// 它们只用于让"本机不支持"这句提示有据可查，不参与任何执行判定。
int SMCChargeProbeKeyCount(void);
const char *SMCChargeProbeKey(int index);

// 整机功率候选键的唯一定义处：SMC.swift 与 MacBatteryHelper/main.swift 均从此读取，
// 避免同一列表在多处不一致。顺序即探测优先级（逐个尝试，取首个读到非零值的键）。
// 用函数式接口暴露，免去 Swift 侧直接消费 C 数组指针的麻烦。
// 返回候选键个数。
int SMCPowerKeyCount(void);
// 返回第 index 个候选键（以 NUL 结尾的只读字符串）；index 越界时返回 NULL。
const char *SMCPowerKey(int index);

#endif