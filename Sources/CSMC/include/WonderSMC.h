#ifndef WONDER_SMC_H
#define WONDER_SMC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int index;
    double current_rpm;
    double minimum_rpm;
    double maximum_rpm;
} WCFanReading;

typedef struct {
    char key[5];
    double celsius;
} WCTemperatureReading;

/* Read-only CPU/GPU sensors. Keys are rediscovered on request, not on every sample. */
int wc_smc_read_temperatures(WCTemperatureReading *readings, int capacity, int rediscover);

/* Read-only, explicitly selected power keys. Unsupported types return NaN. */
double wc_smc_decode_power(const char type[5], const uint8_t *bytes, int size);
typedef struct {
    char key[5];
    double watts;
} WCPowerReading;
int wc_smc_read_power(WCPowerReading *readings, int capacity);

/* Optional IOReport energy counters. Each reader is owned by one serial sampler. */
typedef struct WCEnergyReader WCEnergyReader;
typedef struct {
    char channel[64];
    char unit[8];
    int64_t energy;
} WCEnergyReading;
WCEnergyReader *wc_energy_create(void);
void wc_energy_destroy(WCEnergyReader *reader);
int wc_energy_sample(WCEnergyReader *reader, WCEnergyReading *readings, int capacity, double *elapsed);

int wc_smc_is_available(void);
int wc_smc_fan_count(void);
int wc_smc_fan_control_capabilities(void);
int wc_smc_read_fan(int index, WCFanReading *reading);
int wc_smc_set_all_fans_auto(void);
int wc_smc_set_all_fans_rpm(double rpm);
const char *wc_smc_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
