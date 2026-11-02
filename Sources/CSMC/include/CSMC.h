// CSMC.h — exact C layout of the AppleSMC user-client parameter block.
//
// AppleSMC exposes a single struct-in/struct-out method (selector 2,
// "kSMCHandleYPCEvent"). The sub-command (read / write / key-info / index)
// travels inside the struct in `data8`. The struct MUST be exactly 80 bytes
// with C alignment; declaring it in C (instead of Swift) guarantees that
// `keyInfo` is padded to 12 bytes so `result` lands at offset 40.

#ifndef CSMC_H
#define CSMC_H

#include <stdint.h>

#define SMC_BYTES_LEN 32

// IOConnectCallStructMethod selectors on the AppleSMC user client.
enum {
    kSMCUserClientOpen  = 0,   // legacy, not required on modern macOS
    kSMCUserClientClose = 1,
    kSMCHandleYPCEvent  = 2,   // the only selector actually used
};

// Sub-commands placed in SMCParamStruct.data8.
enum {
    kSMCReadKey         = 5,
    kSMCWriteKey        = 6,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo      = 9,
};

// Values returned by the firmware in SMCParamStruct.result.
enum {
    kSMCSuccess            = 0x00,
    kSMCError              = 0x01,
    kSMCKeyNotFound        = 0x84,
    kSMCKeyNotReadable     = 0x85,
    kSMCKeyNotWritable     = 0x86,
    kSMCKeySizeMismatch    = 0x87,
    kSMCFramingError       = 0x88,
    kSMCBadArgumentError   = 0x89,
    kSMCTimeoutError       = 0xB7,
    kSMCKeyIndexRangeError = 0xB8,
    kSMCBadFuncParameter   = 0xC0,
};

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} SMCVersion;                       // 6 bytes

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;                    // 16 bytes

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;              // FourCharCode, e.g. 'ui8 ', 'flt '
    uint8_t  dataAttributes;
} SMCKeyInfoData;                   // 12 bytes (with tail padding)

typedef struct {
    uint32_t       key;             // FourCharCode, e.g. 'CH0B'
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;           // sub-command
    uint32_t       data32;          // key index for kSMCGetKeyFromIndex
    uint8_t        bytes[SMC_BYTES_LEN];
} SMCParamStruct;                   // 80 bytes

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct must be 80 bytes");
_Static_assert(__builtin_offsetof(SMCParamStruct, result) == 40, "bad layout");

#endif
