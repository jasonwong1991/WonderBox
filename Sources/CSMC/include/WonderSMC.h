#ifndef WONDER_SMC_H
#define WONDER_SMC_H

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
