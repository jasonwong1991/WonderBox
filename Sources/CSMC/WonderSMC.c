#include "WonderSMC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum {
    WC_SMC_INDEX = 2,
    WC_SMC_CMD_READ_BYTES = 5,
    WC_SMC_CMD_WRITE_BYTES = 6,
    WC_SMC_CMD_READ_KEY_INFO = 9
};

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpu_p_limit;
    uint32_t gpu_p_limit;
    uint32_t memory_p_limit;
} SMCPowerLimit;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t data_attributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPowerLimit power_limit;
    SMCKeyInfo key_info;
    uint8_t result;
    uint8_t status;
    uint8_t command;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

typedef struct {
    uint32_t size;
    uint32_t type;
    uint8_t bytes[32];
} SMCValue;

static char wc_last_error[256];

static void clear_last_error(void) {
    wc_last_error[0] = '\0';
}

static void set_last_error(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(wc_last_error, sizeof(wc_last_error), format, arguments);
    va_end(arguments);
}

const char *wc_smc_last_error(void) {
    return wc_last_error;
}

static uint32_t four_char_code(const char key[5]) {
    return ((uint32_t)(uint8_t)key[0] << 24) |
           ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) |
           (uint32_t)(uint8_t)key[3];
}

static kern_return_t smc_open(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) {
        return kIOReturnNotFound;
    }
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}

static kern_return_t smc_call(io_connect_t connection, SMCKeyData *input, SMCKeyData *output) {
    size_t output_size = sizeof(*output);
    return IOConnectCallStructMethod(
        connection,
        WC_SMC_INDEX,
        input,
        sizeof(*input),
        output,
        &output_size
    );
}

static kern_return_t smc_read(io_connect_t connection, const char key[5], SMCValue *value) {
    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = four_char_code(key);
    input.command = WC_SMC_CMD_READ_KEY_INFO;
    kern_return_t result = smc_call(connection, &input, &output);
    if (result != kIOReturnSuccess || output.result != 0) {
        return result != kIOReturnSuccess ? result : kIOReturnError;
    }

    value->size = output.key_info.data_size;
    value->type = output.key_info.data_type;
    input.key_info.data_size = output.key_info.data_size;
    input.command = WC_SMC_CMD_READ_BYTES;
    memset(&output, 0, sizeof(output));
    result = smc_call(connection, &input, &output);
    if (result != kIOReturnSuccess || output.result != 0) {
        return result != kIOReturnSuccess ? result : kIOReturnError;
    }
    memcpy(value->bytes, output.bytes, sizeof(value->bytes));
    return kIOReturnSuccess;
}

static kern_return_t smc_write(io_connect_t connection, const char key[5], const SMCValue *value) {
    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = four_char_code(key);
    input.command = WC_SMC_CMD_READ_KEY_INFO;
    kern_return_t result = smc_call(connection, &input, &output);
    if (result != kIOReturnSuccess || output.result != 0) {
        return result != kIOReturnSuccess ? result : kIOReturnError;
    }

    input.key_info.data_size = output.key_info.data_size;
    input.command = WC_SMC_CMD_WRITE_BYTES;
    memcpy(input.bytes, value->bytes, value->size > 32 ? 32 : value->size);
    memset(&output, 0, sizeof(output));
    result = smc_call(connection, &input, &output);
    if (result != kIOReturnSuccess || output.result != 0) {
        return result != kIOReturnSuccess ? result : kIOReturnNotPrivileged;
    }
    return kIOReturnSuccess;
}

static kern_return_t smc_write_with_retry(
    io_connect_t connection,
    const char key[5],
    const SMCValue *value,
    int attempts,
    useconds_t delay_microseconds
) {
    kern_return_t result = kIOReturnError;
    for (int attempt = 0; attempt < attempts; attempt++) {
        result = smc_write(connection, key, value);
        if (result == kIOReturnSuccess) {
            return result;
        }
        if (attempt + 1 < attempts) {
            usleep(delay_microseconds);
        }
    }
    return result;
}

static double smc_numeric_value(const SMCValue *value) {
    if (value->type == four_char_code("fpe2") && value->size >= 2) {
        uint16_t raw = ((uint16_t)value->bytes[0] << 8) | value->bytes[1];
        return (double)raw / 4.0;
    }
    if (value->type == four_char_code("sp78") && value->size >= 2) {
        int16_t raw = (int16_t)(((uint16_t)value->bytes[0] << 8) | value->bytes[1]);
        return (double)raw / 256.0;
    }
    if (value->type == four_char_code("flt ") && value->size >= 4) {
        float native_number = 0;
        memcpy(&native_number, value->bytes, sizeof(native_number));
        if (isfinite(native_number) && native_number >= -100 && native_number <= 20000) {
            return native_number;
        }
        uint32_t big_endian_bits = ((uint32_t)value->bytes[0] << 24) |
                                   ((uint32_t)value->bytes[1] << 16) |
                                   ((uint32_t)value->bytes[2] << 8) |
                                   value->bytes[3];
        float big_endian_number = 0;
        memcpy(&big_endian_number, &big_endian_bits, sizeof(big_endian_number));
        return big_endian_number;
    }
    if (value->size == 1) {
        return value->bytes[0];
    }
    if (value->size >= 2) {
        return ((uint16_t)value->bytes[0] << 8) | value->bytes[1];
    }
    return NAN;
}

static int smc_encode_number(SMCValue *value, double number) {
    if (value->type == four_char_code("fpe2") && value->size >= 2) {
        uint16_t raw = (uint16_t)lround(fmax(0, fmin(16383.75, number)) * 4.0);
        value->bytes[0] = (uint8_t)(raw >> 8);
        value->bytes[1] = (uint8_t)(raw & 0xff);
        return 0;
    }
    if (value->type == four_char_code("flt ") && value->size >= 4) {
        float raw = (float)number;
        memcpy(value->bytes, &raw, sizeof(raw));
        return 0;
    }
    if ((value->type == four_char_code("ui16") || value->size == 2) && value->size >= 2) {
        uint16_t raw = (uint16_t)lround(fmax(0, fmin(65535, number)));
        value->bytes[0] = (uint8_t)(raw >> 8);
        value->bytes[1] = (uint8_t)(raw & 0xff);
        return 0;
    }
    return -1;
}

static int read_fan_mode(io_connect_t connection, int index, char key[5], SMCValue *mode) {
#if defined(__arm64__) || defined(__aarch64__)
    snprintf(key, 5, "F%dmd", index);
    if (smc_read(connection, key, mode) == kIOReturnSuccess && mode->size > 0) {
        return 0;
    }
#endif
    snprintf(key, 5, "F%dMd", index);
    return smc_read(connection, key, mode) == kIOReturnSuccess && mode->size > 0 ? 0 : -1;
}

static int set_fan_mode_direct(io_connect_t connection, int index, int manual, int attempts) {
    char key[5];
    SMCValue mode;
    if (read_fan_mode(connection, index, key, &mode) != 0) {
        set_last_error("No mode key found for fan %d", index + 1);
        return -1;
    }
    mode.bytes[0] = manual ? 1 : 0;
    kern_return_t result = smc_write_with_retry(connection, key, &mode, attempts, 100000);
    if (result != kIOReturnSuccess) {
        set_last_error("Failed to write %s (0x%08x)", key, result);
        return -1;
    }
    return 0;
}

#if defined(__arm64__) || defined(__aarch64__)
static int unlock_apple_silicon_fan(io_connect_t connection, int index) {
    char mode_key[5];
    SMCValue mode;
    if (read_fan_mode(connection, index, mode_key, &mode) != 0) {
        set_last_error("No Apple Silicon mode key found for fan %d", index + 1);
        return -1;
    }
    if (mode.bytes[0] == 1) {
        return 0;
    }

    mode.bytes[0] = 1;
    if (smc_write(connection, mode_key, &mode) == kIOReturnSuccess) {
        return 0;
    }

    SMCValue test_mode;
    kern_return_t read_result = smc_read(connection, "Ftst", &test_mode);
    if (read_result != kIOReturnSuccess || test_mode.size == 0) {
        set_last_error("%s is protected by the system and the Ftst unlock key is unavailable (0x%08x)", mode_key, read_result);
        return -1;
    }

    if (test_mode.bytes[0] != 1) {
        test_mode.bytes[0] = 1;
        kern_return_t unlock_result = smc_write_with_retry(connection, "Ftst", &test_mode, 100, 50000);
        if (unlock_result != kIOReturnSuccess) {
            set_last_error("Failed to write the Ftst unlock key (0x%08x)", unlock_result);
            return -1;
        }
        // thermalmonitord needs a short handoff window after Ftst is enabled.
        usleep(3000000);
    }

    mode.bytes[0] = 1;
    kern_return_t mode_result = smc_write_with_retry(connection, mode_key, &mode, 300, 100000);
    if (mode_result != kIOReturnSuccess) {
        set_last_error("Ftst is enabled but writing %s still failed (0x%08x)", mode_key, mode_result);
        return -1;
    }
    return 0;
}

static int reset_apple_silicon_fans(io_connect_t connection, int count) {
    int mode_result = 0;
    for (int index = 0; index < count; index++) {
        if (set_fan_mode_direct(connection, index, 0, 20) != 0) {
            mode_result = -1;
        }

        char target_key[5];
        snprintf(target_key, sizeof(target_key), "F%dTg", index);
        SMCValue target;
        if (smc_read(connection, target_key, &target) == kIOReturnSuccess &&
            smc_encode_number(&target, 0) == 0) {
            if (smc_write_with_retry(connection, target_key, &target, 20, 100000) != kIOReturnSuccess) {
                mode_result = -1;
            }
        }
    }

    SMCValue test_mode;
    if (smc_read(connection, "Ftst", &test_mode) == kIOReturnSuccess && test_mode.size > 0) {
        if (test_mode.bytes[0] != 0) {
            test_mode.bytes[0] = 0;
            kern_return_t result = smc_write_with_retry(connection, "Ftst", &test_mode, 20, 100000);
            if (result != kIOReturnSuccess) {
                set_last_error("Failed to restore Ftst automatic control (0x%08x)", result);
                return -1;
            }
        }
        // Give thermalmonitord time to reclaim the fan targets.
        usleep(500000);
        return 0;
    }
    return mode_result;
}
#else
static int set_intel_fan_mode(io_connect_t connection, int index, int manual) {
    SMCValue mask;
    if (smc_read(connection, "FS! ", &mask) == kIOReturnSuccess && mask.size >= 2) {
        uint16_t bits = ((uint16_t)mask.bytes[0] << 8) | mask.bytes[1];
        if (manual) {
            bits |= (uint16_t)(1u << index);
        } else {
            bits &= (uint16_t)~(1u << index);
        }
        mask.bytes[0] = (uint8_t)(bits >> 8);
        mask.bytes[1] = (uint8_t)(bits & 0xff);
        if (smc_write(connection, "FS! ", &mask) == kIOReturnSuccess) {
            return 0;
        }
    }

    return set_fan_mode_direct(connection, index, manual, 1);
}
#endif

static int fan_count_with_connection(io_connect_t connection) {
    SMCValue value;
    int count = 0;
    if (smc_read(connection, "FNum", &value) == kIOReturnSuccess) {
        count = (int)smc_numeric_value(&value);
    }
    if (count <= 0 || count > 8) {
        count = 0;
        for (int index = 0; index < 8; index++) {
            char key[5];
            snprintf(key, sizeof(key), "F%dAc", index);
            if (smc_read(connection, key, &value) == kIOReturnSuccess) {
                count = index + 1;
            }
        }
    }
    return count;
}

int wc_smc_is_available(void) {
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = smc_open(&connection);
    if (result == kIOReturnSuccess) {
        IOServiceClose(connection);
        return 1;
    }
    return 0;
}

int wc_smc_fan_count(void) {
    io_connect_t connection = IO_OBJECT_NULL;
    if (smc_open(&connection) != kIOReturnSuccess) {
        return 0;
    }
    int count = fan_count_with_connection(connection);
    IOServiceClose(connection);
    return count;
}

int wc_smc_fan_control_capabilities(void) {
    io_connect_t connection = IO_OBJECT_NULL;
    if (smc_open(&connection) != kIOReturnSuccess) {
        return 0;
    }

    int capabilities = 0;
    SMCValue value;
    if (smc_read(connection, "F0md", &value) == kIOReturnSuccess && value.size > 0) {
        capabilities |= 1;
    }
    if (smc_read(connection, "F0Md", &value) == kIOReturnSuccess && value.size > 0) {
        capabilities |= 2;
    }
    if (smc_read(connection, "Ftst", &value) == kIOReturnSuccess && value.size > 0) {
        capabilities |= 4;
    }
    if (smc_read(connection, "F0Tg", &value) == kIOReturnSuccess && value.size > 0) {
        capabilities |= 8;
    }
    IOServiceClose(connection);
    return capabilities;
}

int wc_smc_read_fan(int index, WCFanReading *reading) {
    if (reading == NULL || index < 0 || index > 9) {
        return -1;
    }
    io_connect_t connection = IO_OBJECT_NULL;
    if (smc_open(&connection) != kIOReturnSuccess) {
        return -2;
    }

    char key[5];
    SMCValue value;
    memset(reading, 0, sizeof(*reading));
    reading->index = index;

    snprintf(key, sizeof(key), "F%dAc", index);
    if (smc_read(connection, key, &value) != kIOReturnSuccess) {
        IOServiceClose(connection);
        return -3;
    }
    reading->current_rpm = smc_numeric_value(&value);

    snprintf(key, sizeof(key), "F%dMn", index);
    if (smc_read(connection, key, &value) == kIOReturnSuccess) {
        reading->minimum_rpm = smc_numeric_value(&value);
    }
    snprintf(key, sizeof(key), "F%dMx", index);
    if (smc_read(connection, key, &value) == kIOReturnSuccess) {
        reading->maximum_rpm = smc_numeric_value(&value);
    }
    IOServiceClose(connection);
    if (!isfinite(reading->current_rpm) || reading->current_rpm < 0 || reading->current_rpm > 20000) {
        return -4;
    }
    if (!isfinite(reading->minimum_rpm) || reading->minimum_rpm < 0 || reading->minimum_rpm > 20000) {
        reading->minimum_rpm = 0;
    }
    if (!isfinite(reading->maximum_rpm) || reading->maximum_rpm < reading->minimum_rpm || reading->maximum_rpm > 20000) {
        reading->maximum_rpm = 0;
    }
    return 0;
}

int wc_smc_set_all_fans_auto(void) {
    clear_last_error();
    io_connect_t connection = IO_OBJECT_NULL;
    if (smc_open(&connection) != kIOReturnSuccess) {
        set_last_error("Cannot connect to AppleSMC");
        return -2;
    }
    int count = fan_count_with_connection(connection);
    if (count <= 0) {
        set_last_error("No controllable fans detected");
        IOServiceClose(connection);
        return -3;
    }
#if defined(__arm64__) || defined(__aarch64__)
    int result = reset_apple_silicon_fans(connection, count);
#else
    int result = 0;
    for (int index = 0; index < count; index++) {
        if (set_intel_fan_mode(connection, index, 0) != 0) {
            result = -3;
        }
    }
#endif
    IOServiceClose(connection);
    return result;
}

int wc_smc_set_all_fans_rpm(double rpm) {
    clear_last_error();
    io_connect_t connection = IO_OBJECT_NULL;
    if (smc_open(&connection) != kIOReturnSuccess) {
        set_last_error("Cannot connect to AppleSMC");
        return -2;
    }
    int count = fan_count_with_connection(connection);
    if (count <= 0) {
        set_last_error("No controllable fans detected");
        IOServiceClose(connection);
        return -3;
    }
    int result = 0;
    for (int index = 0; index < count; index++) {
#if defined(__arm64__) || defined(__aarch64__)
        if (unlock_apple_silicon_fan(connection, index) != 0) {
            result = -3;
            break;
        }
#else
        if (set_intel_fan_mode(connection, index, 1) != 0) {
            result = -3;
            break;
        }
#endif
        char key[5];
        snprintf(key, sizeof(key), "F%dTg", index);
        SMCValue target;
        kern_return_t read_result = smc_read(connection, key, &target);
        if (read_result != kIOReturnSuccess) {
            set_last_error("Failed to read %s (0x%08x)", key, read_result);
            result = -3;
            break;
        }
        if (smc_encode_number(&target, rpm) != 0) {
            set_last_error("%s uses an unknown value format", key);
            result = -3;
            break;
        }
#if defined(__arm64__) || defined(__aarch64__)
        kern_return_t write_result = smc_write_with_retry(connection, key, &target, 10, 50000);
#else
        kern_return_t write_result = smc_write(connection, key, &target);
#endif
        if (write_result != kIOReturnSuccess) {
            set_last_error("Failed to write %s (0x%08x)", key, write_result);
            result = -3;
            break;
        }
    }
    if (result != 0) {
#if defined(__arm64__) || defined(__aarch64__)
        char failure[sizeof(wc_last_error)];
        strlcpy(failure, wc_last_error, sizeof(failure));
        reset_apple_silicon_fans(connection, count);
        strlcpy(wc_last_error, failure, sizeof(wc_last_error));
#else
        for (int index = 0; index < count; index++) {
            set_intel_fan_mode(connection, index, 0);
        }
#endif
    }
    IOServiceClose(connection);
    return result;
}
