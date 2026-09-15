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

// 整机功率候选键的唯一定义处：SMC.swift 与 MacBatteryHelper/main.swift 均从此读取，
// 避免同一列表在多处不一致。顺序即探测优先级（逐个尝试，取首个读到非零值的键）。
// 用函数式接口暴露，免去 Swift 侧直接消费 C 数组指针的麻烦。
// 返回候选键个数。
int SMCPowerKeyCount(void);
// 返回第 index 个候选键（以 NUL 结尾的只读字符串）；index 越界时返回 NULL。
const char *SMCPowerKey(int index);

#endif