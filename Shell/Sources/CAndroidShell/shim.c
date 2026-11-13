#include "include/CAndroidShell.h"
#include <sys/system_properties.h>
#include <string.h>

void switchlings_log(int priority, const char *tag, const char *message) {
    __android_log_write(priority, tag, message);
}

int switchlings_property(const char *name, char *out, int capacity) {
    char value[PROP_VALUE_MAX];
    int length = __system_property_get(name, value);
    if (length <= 0 || capacity <= 0) {
        if (capacity > 0) { out[0] = '\0'; }
        return 0;
    }
    if (length >= capacity) { length = capacity - 1; }
    memcpy(out, value, (size_t)length);
    out[length] = '\0';
    return length;
}
