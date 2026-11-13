#include <dlfcn.h>
#include "include/CAndroidShell.h"
#include <sys/system_properties.h>
#include <string.h>
#include <jni.h>

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

// libdispatch's own: the main queue's address, the queue the calling thread
// runs on, and CoreFoundation's door into draining the main queue (which a
// run loop calls on Apple). Declared here rather than through
// <dispatch/dispatch.h>, which the NDK does not ship.
extern char _dispatch_main_q;
extern void *dispatch_get_current_queue(void);
extern void _dispatch_main_queue_callback_4CF(void *ignored);

bool switchlings_owns_main_queue(void) {
    return dispatch_get_current_queue() == (void *)&_dispatch_main_q;
}

void switchlings_drain_main_queue(void) {
    _dispatch_main_queue_callback_4CF(0);
}

bool switchlings_share_file(const char *path, const char *mime, const char *text) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (env == NULL || activity == NULL) return false;
    jclass cls = (*env)->GetObjectClass(env, activity);
    jmethodID share = (*env)->GetMethodID(env, cls, "shareFile", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
    bool ok = share != NULL;
    if (ok) {
        jstring jpath = (*env)->NewStringUTF(env, path);
        jstring jmime = (*env)->NewStringUTF(env, mime);
        jstring jtext = text != NULL ? (*env)->NewStringUTF(env, text) : NULL;
        (*env)->CallVoidMethod(env, activity, share, jpath, jmime, jtext);
        if (jtext != NULL) (*env)->DeleteLocalRef(env, jtext);
        (*env)->DeleteLocalRef(env, jmime);
        (*env)->DeleteLocalRef(env, jpath);
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        ok = false;
    }
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, activity);
    return ok;
}
