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
