#include <dlfcn.h>
#include "include/CAndroidShell.h"
#include <sys/system_properties.h>
#include <string.h>
#include <jni.h>
#include <stdatomic.h>
#include <stdlib.h>

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

static atomic_int switchlings_platform_pending;

static void JNICALL switchlings_platform_events_ready(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    atomic_store(&switchlings_platform_pending, 1);
}

bool switchlings_platform_install(void) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (env == NULL || activity == NULL) return false;
    jclass cls = (*env)->GetObjectClass(env, activity);
    JNINativeMethod methods[] = {
        { "nativePlatformEventsReady", "()V", (void *)switchlings_platform_events_ready },
    };
    bool ok = (*env)->RegisterNatives(env, cls, methods, 1) == JNI_OK;
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        ok = false;
    }
    if (ok) {
        jfieldID registered = (*env)->GetStaticFieldID(env, cls, "nativePlatformRegistered", "Z");
        if (registered != NULL) (*env)->SetStaticBooleanField(env, cls, registered, JNI_TRUE);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, activity);
    // Whatever Java queued before the method existed is drained now.
    atomic_store(&switchlings_platform_pending, 1);
    return ok;
}

bool switchlings_platform_take_pending(void) {
    return atomic_exchange(&switchlings_platform_pending, 0) != 0;
}

/* Copies a Java byte[] into a malloc'd buffer, or NULL. Frees the local ref. */
static unsigned char *switchlings_copy_bytes(JNIEnv *env, jbyteArray array, int *out_length) {
    *out_length = 0;
    if (array == NULL) return NULL;
    jsize length = (*env)->GetArrayLength(env, array);
    unsigned char *buffer = malloc((size_t)length + 1);
    if (buffer != NULL) {
        (*env)->GetByteArrayRegion(env, array, 0, length, (jbyte *)buffer);
        buffer[length] = 0;
        *out_length = (int)length;
    }
    (*env)->DeleteLocalRef(env, array);
    return buffer;
}

static unsigned char *switchlings_platform_invoke(const char *method, const char *signature, const char *name,
                                                  const unsigned char *args, int length, int *out_length) {
    *out_length = 0;
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (env == NULL || activity == NULL) return NULL;
    jclass cls = (*env)->GetObjectClass(env, activity);
    jmethodID id = (*env)->GetMethodID(env, cls, method, signature);
    unsigned char *result = NULL;
    if (id != NULL) {
        jbyteArray answer;
        if (name != NULL) {
            jstring jname = (*env)->NewStringUTF(env, name);
            jbyteArray jargs = (*env)->NewByteArray(env, length);
            if (jargs != NULL && length > 0) (*env)->SetByteArrayRegion(env, jargs, 0, length, (const jbyte *)args);
            answer = (jbyteArray)(*env)->CallObjectMethod(env, activity, id, jname, jargs);
            if (jargs != NULL) (*env)->DeleteLocalRef(env, jargs);
            (*env)->DeleteLocalRef(env, jname);
        } else {
            answer = (jbyteArray)(*env)->CallObjectMethod(env, activity, id);
        }
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            answer = NULL;
        }
        result = switchlings_copy_bytes(env, answer, out_length);
    }
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, activity);
    return result;
}

unsigned char *switchlings_platform_call(const char *name, const unsigned char *args, int length, int *out_length) {
    return switchlings_platform_invoke("platformCall", "(Ljava/lang/String;[B)[B", name, args, length, out_length);
}

unsigned char *switchlings_platform_drain(int *out_length) {
    return switchlings_platform_invoke("platformDrain", "()[B", NULL, NULL, 0, out_length);
}
/* What Android tells the game outside SDL's events: a link the activity was
   handed while running (`onNewIntent`), the soft keyboard's insets, and text
   picked from the Paste a long press offers. `MainActivity` calls its native
   methods on Android's UI thread; the frame loop takes what they left on
   SDL's. Registered on the activity's own class, because SDL dlopens this
   library itself, so the class loader never looks in it for natives. */

#include <pthread.h>
#include <stdlib.h>

static pthread_mutex_t switchlings_inbox_lock = PTHREAD_MUTEX_INITIALIZER;
#define SWITCHLINGS_INBOX_CAPACITY 8
static char *switchlings_links[SWITCHLINGS_INBOX_CAPACITY];
static int switchlings_link_count;
static char *switchlings_pastes[SWITCHLINGS_INBOX_CAPACITY];
static int switchlings_paste_count;
static int switchlings_keyboard[2];
static bool switchlings_keyboard_changed;

static void switchlings_push(JNIEnv *env, jstring text, char **queue, int *count) {
    if (text == NULL) return;
    const char *utf = (*env)->GetStringUTFChars(env, text, NULL);
    if (utf == NULL) return;
    pthread_mutex_lock(&switchlings_inbox_lock);
    if (*count < SWITCHLINGS_INBOX_CAPACITY) {
        queue[(*count)++] = strdup(utf);
    }
    pthread_mutex_unlock(&switchlings_inbox_lock);
    (*env)->ReleaseStringUTFChars(env, text, utf);
}

static void JNICALL switchlings_native_open_link(JNIEnv *env, jclass cls, jstring link) {
    (void)cls;
    switchlings_push(env, link, switchlings_links, &switchlings_link_count);
}

static void JNICALL switchlings_native_paste(JNIEnv *env, jclass cls, jstring text) {
    (void)cls;
    switchlings_push(env, text, switchlings_pastes, &switchlings_paste_count);
}

static void JNICALL switchlings_native_keyboard(JNIEnv *env, jclass cls, jint height, jint viewHeight) {
    (void)env;
    (void)cls;
    pthread_mutex_lock(&switchlings_inbox_lock);
    switchlings_keyboard[0] = height;
    switchlings_keyboard[1] = viewHeight;
    switchlings_keyboard_changed = true;
    pthread_mutex_unlock(&switchlings_inbox_lock);
}

bool switchlings_register_natives(void) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (env == NULL || activity == NULL) return false;
    jclass cls = (*env)->GetObjectClass(env, activity);
    JNINativeMethod methods[] = {
        { "nativeOpenLink", "(Ljava/lang/String;)V", (void *)switchlings_native_open_link },
        { "nativePaste", "(Ljava/lang/String;)V", (void *)switchlings_native_paste },
        { "nativeKeyboard", "(II)V", (void *)switchlings_native_keyboard },
    };
    bool ok = (*env)->RegisterNatives(env, cls, methods, sizeof(methods) / sizeof(methods[0])) == JNI_OK;
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        ok = false;
    }
    if (ok) {
        jmethodID ready = (*env)->GetMethodID(env, cls, "nativesRegistered", "()V");
        if (ready != NULL) (*env)->CallVoidMethod(env, activity, ready);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, activity);
    return ok;
}

static char *switchlings_pop(char **queue, int *count) {
    pthread_mutex_lock(&switchlings_inbox_lock);
    char *first = NULL;
    if (*count > 0) {
        first = queue[0];
        memmove(queue, queue + 1, sizeof(char *) * (size_t)(*count - 1));
        (*count)--;
    }
    pthread_mutex_unlock(&switchlings_inbox_lock);
    return first;
}

char *switchlings_take_link(void) { return switchlings_pop(switchlings_links, &switchlings_link_count); }

char *switchlings_take_paste(void) { return switchlings_pop(switchlings_pastes, &switchlings_paste_count); }

bool switchlings_take_keyboard(int *height, int *viewHeight) {
    pthread_mutex_lock(&switchlings_inbox_lock);
    bool changed = switchlings_keyboard_changed;
    if (changed) {
        *height = switchlings_keyboard[0];
        *viewHeight = switchlings_keyboard[1];
        switchlings_keyboard_changed = false;
    }
    pthread_mutex_unlock(&switchlings_inbox_lock);
    return changed;
}

bool switchlings_offer_paste(float x, float y) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (env == NULL || activity == NULL) return false;
    jclass cls = (*env)->GetObjectClass(env, activity);
    jmethodID offer = (*env)->GetMethodID(env, cls, "offerPaste", "(FF)V");
    bool ok = offer != NULL;
    if (ok) (*env)->CallVoidMethod(env, activity, offer, (jfloat)x, (jfloat)y);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        ok = false;
    }
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, activity);
    return ok;
}
