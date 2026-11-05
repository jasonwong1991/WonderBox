#include "WonderSMC.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int has_suffix(const char *text, const char *suffix) {
    size_t length = strlen(text), suffix_length = strlen(suffix);
    return length >= suffix_length && strcmp(text + length - suffix_length, suffix) == 0;
}

// IOReport is optional/private. Resolve every symbol before use so other macOS
// versions/Intel can fall back to SMC without a launch-time linker failure.
struct WCEnergyReader {
    void *library;
    CFTypeRef subscription;
    CFMutableDictionaryRef channels;
    CFDictionaryRef previous;
    double previous_time;
    CFDictionaryRef (*sample)(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
    CFDictionaryRef (*delta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    CFStringRef (*name)(CFDictionaryRef);
    CFStringRef (*unit)(CFDictionaryRef);
    int64_t (*value)(CFDictionaryRef, int32_t);
};

void wc_energy_destroy(WCEnergyReader *reader) {
    if (!reader) return;
    if (reader->previous) CFRelease(reader->previous);
    if (reader->subscription) CFRelease(reader->subscription);
    if (reader->channels) CFRelease(reader->channels);
    if (reader->library) dlclose(reader->library);
    free(reader);
}

WCEnergyReader *wc_energy_create(void) {
#if !defined(__arm64__) && !defined(__aarch64__)
    return NULL;
#else
    WCEnergyReader *reader = calloc(1, sizeof(*reader));
    if (!reader) return NULL;
    reader->library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!reader->library) { wc_energy_destroy(reader); return NULL; }
    CFDictionaryRef (*copy)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t) = dlsym(reader->library, "IOReportCopyChannelsInGroup");
    CFTypeRef (*subscribe)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef) = dlsym(reader->library, "IOReportCreateSubscription");
    reader->sample = dlsym(reader->library, "IOReportCreateSamples");
    reader->delta = dlsym(reader->library, "IOReportCreateSamplesDelta");
    reader->name = dlsym(reader->library, "IOReportChannelGetChannelName");
    reader->unit = dlsym(reader->library, "IOReportChannelGetUnitLabel");
    reader->value = dlsym(reader->library, "IOReportSimpleGetIntegerValue");
    if (!copy || !subscribe || !reader->sample || !reader->delta || !reader->name || !reader->unit || !reader->value) {
        wc_energy_destroy(reader); return NULL;
    }
    CFDictionaryRef raw = copy(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!raw) { wc_energy_destroy(reader); return NULL; }
    reader->channels = CFDictionaryCreateMutableCopy(NULL, 0, raw);
    CFRelease(raw);
    if (!reader->channels) { wc_energy_destroy(reader); return NULL; }
    CFMutableDictionaryRef subscribed = NULL;
    reader->subscription = subscribe(NULL, reader->channels, &subscribed, 0, NULL);
    if (subscribed) { CFRelease(reader->channels); reader->channels = subscribed; }
    if (!reader->subscription) { wc_energy_destroy(reader); return NULL; }
    return reader;
#endif
}

int wc_energy_sample(WCEnergyReader *reader, WCEnergyReading *readings, int capacity, double *elapsed) {
    if (elapsed) *elapsed = 0;
    if (!reader || !readings || capacity <= 0 || !elapsed) return 0;
    CFDictionaryRef current = reader->sample(reader->subscription, reader->channels, NULL);
    if (!current) {
        if (reader->previous) { CFRelease(reader->previous); reader->previous = NULL; }
        return 0;
    }
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    double now = (double)time.tv_sec + (double)time.tv_nsec / 1e9;
    double interval = now - reader->previous_time;
    // Don't turn wake/resume gaps into live power or divide by a tiny interval.
    CFDictionaryRef delta = reader->previous && interval >= 0.5 && interval <= 10
        ? reader->delta(reader->previous, current, NULL) : NULL;
    if (reader->previous) CFRelease(reader->previous);
    reader->previous = current;
    reader->previous_time = now;
    if (!delta) return 0;
    *elapsed = interval;
    int found = 0;
    CFTypeRef channels = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (channels && CFGetTypeID(channels) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(channels); i++) {
            CFTypeRef channel = CFArrayGetValueAtIndex(channels, i);
            if (CFGetTypeID(channel) != CFDictionaryGetTypeID()) continue;
            CFStringRef name = reader->name(channel), unit = reader->unit(channel);
            if (!name || !unit) continue;
            WCEnergyReading value = {0};
            if (!CFStringGetCString(name, value.channel, sizeof(value.channel), kCFStringEncodingUTF8)
                || !CFStringGetCString(unit, value.unit, sizeof(value.unit), kCFStringEncodingUTF8)) continue;
            // Pass total, per-die and per-type CPU energy counters to Swift, which
            // selects one complete family. Do not pass raw per-core/rail counters.
            if (!has_suffix(value.channel, "CPU Energy") && !has_suffix(value.channel, "CPUs Energy")
                && strcmp(value.channel, "GPU Energy") != 0 && strcmp(value.channel, "GPU") != 0) continue;
            // A truncated family could underreport CPU power. Reject the interval instead.
            if (found == capacity) { CFRelease(delta); *elapsed = 0; return 0; }
            value.energy = reader->value(channel, 0);
            readings[found++] = value;
        }
    }
    CFRelease(delta);
    return found;
}
