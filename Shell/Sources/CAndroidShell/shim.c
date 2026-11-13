#include <dlfcn.h>
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

/* The runtime's SerialExecutorRef: the executor object and its witness
   table (with flag bits), two words returned in registers. */
typedef struct {
    const void *identity;
    uintptr_t implementation;
} SwitchlingsExecutorRef;

typedef SwitchlingsExecutorRef (__attribute__((swiftcall)) *SwitchlingsGetMainOriginal)(void);
typedef SwitchlingsExecutorRef (__attribute__((swiftcall)) *SwitchlingsGetMainHook)(SwitchlingsGetMainOriginal);

static SwitchlingsExecutorRef switchlings_main_executor;

static SwitchlingsExecutorRef __attribute__((swiftcall))
switchlings_get_main_executor(SwitchlingsGetMainOriginal original) {
    (void)original;
    return switchlings_main_executor;
}

int switchlings_set_main_executor(const void *identity, uintptr_t implementation) {
    SwitchlingsGetMainHook *hook = (SwitchlingsGetMainHook *)dlsym(RTLD_DEFAULT, "swift_task_getMainExecutor_hook");
    if (hook == NULL) { return 0; }
    switchlings_main_executor.identity = identity;
    switchlings_main_executor.implementation = implementation;
    *hook = switchlings_get_main_executor;
    return 1;
}
