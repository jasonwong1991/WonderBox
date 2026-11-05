#include "WonderSMC.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/sysctl.h>

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
    CFStringRef (*group)(CFDictionaryRef);
    int64_t (*value)(CFDictionaryRef, int32_t);
};

// Independently identified in Apple's 27.2 (26B123) M6 kernel cache.
// See docs/firmware/m6-27.2-clpc.json; unknown drivers/builds have no mapping.
uint64_t wc_energy_clpc_cpu_report_id(const char *bundle, const char *os_build) {
    if (!bundle || !os_build) return 0;
    if (strcmp(bundle, "com.apple.driver.AppleT8152CLPC") == 0 && strcmp(os_build, "26B123") == 0) {
        return 0x00000010485d4bfcULL;
    }
    return 0;
}

static CFMutableDictionaryRef clpc_cpu_channel(uint64_t driver, uint64_t report) {
    int64_t channel_type = 1LL | (2LL << 16) | (1LL << 32);
    int64_t energy_unit = (3LL << 56) | (118LL << 32); // IOReport integer energy, nanojoules.
    int64_t driver_value = (int64_t)driver, report_value = (int64_t)report;
    CFNumberRef driver_number = CFNumberCreate(NULL, kCFNumberSInt64Type, &driver_value);
    CFNumberRef report_number = CFNumberCreate(NULL, kCFNumberSInt64Type, &report_value);
    CFNumberRef type_number = CFNumberCreate(NULL, kCFNumberSInt64Type, &channel_type);
    CFNumberRef unit_number = CFNumberCreate(NULL, kCFNumberSInt64Type, &energy_unit);
    const void *legend_values[] = {report_number, type_number, CFSTR("CPU Energy")};
    CFArrayRef legend = CFArrayCreate(NULL, legend_values, 3, &kCFTypeArrayCallBacks);
    const void *info_keys[] = {CFSTR("IOReportChannelUnit")}, *info_values[] = {unit_number};
    CFDictionaryRef info = CFDictionaryCreate(NULL, info_keys, info_values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef channel = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(channel, CFSTR("DriverID"), driver_number);
    CFDictionarySetValue(channel, CFSTR("DriverName"), CFSTR("AppleCLPC"));
    CFDictionarySetValue(channel, CFSTR("IOReportGroupName"), CFSTR("CLPC"));
    CFDictionarySetValue(channel, CFSTR("IOReportSubGroupName"), CFSTR("Energy Counters"));
    CFDictionarySetValue(channel, CFSTR("IOReportChannelInfo"), info);
    CFDictionarySetValue(channel, CFSTR("LegendChannel"), legend);
    CFRelease(info); CFRelease(legend); CFRelease(unit_number);
    CFRelease(type_number); CFRelease(report_number); CFRelease(driver_number);
    return channel;
}

static void append_clpc_cpu_channels(CFMutableDictionaryRef channels) {
    char build[64] = {0}; size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) != 0) return;
    CFTypeRef original = CFDictionaryGetValue(channels, CFSTR("IOReportChannels"));
    if (original && CFGetTypeID(original) != CFArrayGetTypeID()) return;
    CFMutableArrayRef selected = original ? CFArrayCreateMutableCopy(NULL, 0, original)
        : CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLPC"), &iterator) == KERN_SUCCESS) {
        io_service_t entry;
        while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            CFTypeRef bundle = IORegistryEntryCreateCFProperty(entry, CFSTR("CFBundleIdentifier"), kCFAllocatorDefault, 0);
            char identifier[128] = {0}; uint64_t driver = 0;
            if (bundle && CFGetTypeID(bundle) == CFStringGetTypeID()
                && CFStringGetCString(bundle, identifier, sizeof(identifier), kCFStringEncodingUTF8)
                && IORegistryEntryGetRegistryEntryID(entry, &driver) == KERN_SUCCESS) {
                uint64_t report = wc_energy_clpc_cpu_report_id(identifier, build);
                if (report) {
                    CFMutableDictionaryRef channel = clpc_cpu_channel(driver, report);
                    CFArrayAppendValue(selected, channel);
                    CFRelease(channel);
                }
            }
            if (bundle) CFRelease(bundle);
            IOObjectRelease(entry);
        }
        IOObjectRelease(iterator);
    }
    CFDictionarySetValue(channels, CFSTR("IOReportChannels"), selected);
    CFRelease(selected);
}

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
    reader->group = dlsym(reader->library, "IOReportChannelGetGroup");
    reader->value = dlsym(reader->library, "IOReportSimpleGetIntegerValue");
    if (!copy || !subscribe || !reader->sample || !reader->delta || !reader->name || !reader->unit || !reader->value) {
        wc_energy_destroy(reader); return NULL;
    }
    CFDictionaryRef raw = copy(CFSTR("Energy Model"), NULL, 0, 0, 0);
    reader->channels = raw ? CFDictionaryCreateMutableCopy(NULL, 0, raw)
        : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (raw) CFRelease(raw);
    if (!reader->channels) { wc_energy_destroy(reader); return NULL; }
    if (reader->group) append_clpc_cpu_channels(reader->channels);
    CFTypeRef selected = CFDictionaryGetValue(reader->channels, CFSTR("IOReportChannels"));
    if (!selected || CFGetTypeID(selected) != CFArrayGetTypeID() || CFArrayGetCount(selected) == 0) {
        wc_energy_destroy(reader); return NULL;
    }
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
            CFStringRef group = reader->group ? reader->group(channel) : NULL;
            value.source = group && CFEqual(group, CFSTR("CLPC")) ? 1 : 0;
            readings[found++] = value;
        }
    }
    CFRelease(delta);
    return found;
}
