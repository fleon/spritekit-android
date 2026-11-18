#include <dlfcn.h>
#include "include/CAndroidShell.h"
#include <sys/system_properties.h>
#include <string.h>
#include <jni.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

void ska_log(int priority, const char *tag, const char *message) {
    __android_log_write(priority, tag, message);
}

int ska_property(const char *name, char *out, int capacity) {
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
} SkaExecutorRef;

typedef SkaExecutorRef (__attribute__((swiftcall)) *SkaGetMainOriginal)(void);
typedef SkaExecutorRef (__attribute__((swiftcall)) *SkaGetMainHook)(SkaGetMainOriginal);

static SkaExecutorRef ska_main_executor;

static SkaExecutorRef __attribute__((swiftcall))
ska_get_main_executor(SkaGetMainOriginal original) {
    (void)original;
    return ska_main_executor;
}

int ska_set_main_executor(const void *identity, uintptr_t implementation) {
    SkaGetMainHook *hook = (SkaGetMainHook *)dlsym(RTLD_DEFAULT, "swift_task_getMainExecutor_hook");
    if (hook == NULL) { return 0; }
    ska_main_executor.identity = identity;
    ska_main_executor.implementation = implementation;
    *hook = ska_get_main_executor;
    return 1;
}

// libdispatch's own: the main queue's address, the queue the calling thread
// runs on, and CoreFoundation's door into draining the main queue (which a
// run loop calls on Apple). Declared here rather than through
// <dispatch/dispatch.h>, which the NDK does not ship.
extern char _dispatch_main_q;
extern void *dispatch_get_current_queue(void);
extern void _dispatch_main_queue_callback_4CF(void *ignored);

bool ska_owns_main_queue(void) {
    return dispatch_get_current_queue() == (void *)&_dispatch_main_q;
}

void ska_drain_main_queue(void) {
    _dispatch_main_queue_callback_4CF(0);
}

bool ska_share_file(const char *path, const char *mime, const char *text) {
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

/* The class the activity's natives are declared on: the runtime's library
   activity when the game's extends it, else the game's own (an app whose
   activity still carries them itself). Registering on the declaring class
   spares ART's walk up the superclasses, which CheckJNI warns about. */
static jclass ska_natives_class(JNIEnv *env, jobject activity) {
    jclass library = (*env)->FindClass(env, "com/spritekit/platform/SpriteKitActivity");
    if (library == NULL) {
        (*env)->ExceptionClear(env);
    } else if ((*env)->IsInstanceOf(env, activity, library)) {
        return library;
    } else {
        (*env)->DeleteLocalRef(env, library);
    }
    return (*env)->GetObjectClass(env, activity);
}

static atomic_int ska_platform_pending;

static void JNICALL ska_platform_events_ready(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    atomic_store(&ska_platform_pending, 1);
}

bool ska_platform_install(void) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (env == NULL || activity == NULL) return false;
    jclass cls = ska_natives_class(env, activity);
    JNINativeMethod methods[] = {
        { "nativePlatformEventsReady", "()V", (void *)ska_platform_events_ready },
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
    atomic_store(&ska_platform_pending, 1);
    return ok;
}

bool ska_platform_take_pending(void) {
    return atomic_exchange(&ska_platform_pending, 0) != 0;
}

/* Copies a Java byte[] into a malloc'd buffer, or NULL. Frees the local ref. */
static unsigned char *ska_copy_bytes(JNIEnv *env, jbyteArray array, int *out_length) {
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

static unsigned char *ska_platform_invoke(const char *method, const char *signature, const char *name,
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
        result = ska_copy_bytes(env, answer, out_length);
    }
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, activity);
    return result;
}

unsigned char *ska_platform_call(const char *name, const unsigned char *args, int length, int *out_length) {
    return ska_platform_invoke("platformCall", "(Ljava/lang/String;[B)[B", name, args, length, out_length);
}

unsigned char *ska_platform_drain(int *out_length) {
    return ska_platform_invoke("platformDrain", "()[B", NULL, NULL, 0, out_length);
}

/* What the game prints, line by line, into logcat. */
static int ska_stdio_pipe[2] = { -1, -1 };
/* The app's logcat tag, for C that logs too: `ska_redirect_stdio` sets it. */
const char *ska_log_tag = "SpriteKit";

static void *ska_pump_stdio(void *ignored) {
    (void)ignored;
    char buffer[4096];
    size_t used = 0;
    for (;;) {
        ssize_t got = read(ska_stdio_pipe[0], buffer + used, sizeof(buffer) - 1 - used);
        if (got <= 0) break;
        used += (size_t)got;
        size_t start = 0;
        for (size_t at = 0; at < used; at++) {
            if (buffer[at] != '\n') continue;
            buffer[at] = '\0';
            __android_log_write(ANDROID_LOG_INFO, ska_log_tag, buffer + start);
            start = at + 1;
        }
        if (start > 0) {
            memmove(buffer, buffer + start, used - start);
            used -= start;
        } else if (used == sizeof(buffer) - 1) {
            /* A line longer than the buffer goes out in pieces. */
            buffer[used] = '\0';
            __android_log_write(ANDROID_LOG_INFO, ska_log_tag, buffer);
            used = 0;
        }
    }
    return NULL;
}

bool ska_redirect_stdio(const char *tag) {
    if (ska_stdio_pipe[0] >= 0) return true;
    if (pipe(ska_stdio_pipe) != 0) return false;
    ska_log_tag = strdup(tag);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    dup2(ska_stdio_pipe[1], STDOUT_FILENO);
    dup2(ska_stdio_pipe[1], STDERR_FILENO);
    pthread_t thread;
    if (pthread_create(&thread, NULL, ska_pump_stdio, NULL) != 0) return false;
    pthread_detach(thread);
    return true;
}
/* What Android tells the game outside SDL's events: a link the activity was
   handed while running (`onNewIntent`), the soft keyboard's insets, and text
   picked from the Paste a long press offers. `SpriteKitActivity` calls its
   native methods on Android's UI thread; the frame loop takes what they left
   on SDL's. Registered on the class that declares them
   (`ska_natives_class`), because SDL dlopens this library itself, so the
   class loader never looks in it for natives. */

#include <pthread.h>
#include <stdlib.h>

static pthread_mutex_t ska_inbox_lock = PTHREAD_MUTEX_INITIALIZER;
#define SKA_INBOX_CAPACITY 8
static char *ska_links[SKA_INBOX_CAPACITY];
static int ska_link_count;
static char *ska_pastes[SKA_INBOX_CAPACITY];
static int ska_paste_count;
static int ska_keyboard[2];
static bool ska_keyboard_changed;

static void ska_push(JNIEnv *env, jstring text, char **queue, int *count) {
    if (text == NULL) return;
    const char *utf = (*env)->GetStringUTFChars(env, text, NULL);
    if (utf == NULL) return;
    pthread_mutex_lock(&ska_inbox_lock);
    if (*count < SKA_INBOX_CAPACITY) {
        queue[(*count)++] = strdup(utf);
    }
    pthread_mutex_unlock(&ska_inbox_lock);
    (*env)->ReleaseStringUTFChars(env, text, utf);
}

static void JNICALL ska_native_open_link(JNIEnv *env, jclass cls, jstring link) {
    (void)cls;
    ska_push(env, link, ska_links, &ska_link_count);
}

static void JNICALL ska_native_paste(JNIEnv *env, jclass cls, jstring text) {
    (void)cls;
    ska_push(env, text, ska_pastes, &ska_paste_count);
}

static void JNICALL ska_native_keyboard(JNIEnv *env, jclass cls, jint height, jint viewHeight) {
    (void)env;
    (void)cls;
    pthread_mutex_lock(&ska_inbox_lock);
    ska_keyboard[0] = height;
    ska_keyboard[1] = viewHeight;
    ska_keyboard_changed = true;
    pthread_mutex_unlock(&ska_inbox_lock);
}

bool ska_register_natives(void) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (env == NULL || activity == NULL) return false;
    jclass cls = ska_natives_class(env, activity);
    JNINativeMethod methods[] = {
        { "nativeOpenLink", "(Ljava/lang/String;)V", (void *)ska_native_open_link },
        { "nativePaste", "(Ljava/lang/String;)V", (void *)ska_native_paste },
        { "nativeKeyboard", "(II)V", (void *)ska_native_keyboard },
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

static char *ska_pop(char **queue, int *count) {
    pthread_mutex_lock(&ska_inbox_lock);
    char *first = NULL;
    if (*count > 0) {
        first = queue[0];
        memmove(queue, queue + 1, sizeof(char *) * (size_t)(*count - 1));
        (*count)--;
    }
    pthread_mutex_unlock(&ska_inbox_lock);
    return first;
}

char *ska_take_link(void) { return ska_pop(ska_links, &ska_link_count); }

char *ska_take_paste(void) { return ska_pop(ska_pastes, &ska_paste_count); }

bool ska_take_keyboard(int *height, int *viewHeight) {
    pthread_mutex_lock(&ska_inbox_lock);
    bool changed = ska_keyboard_changed;
    if (changed) {
        *height = ska_keyboard[0];
        *viewHeight = ska_keyboard[1];
        ska_keyboard_changed = false;
    }
    pthread_mutex_unlock(&ska_inbox_lock);
    return changed;
}

bool ska_offer_paste(float x, float y) {
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

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    EGLDisplay display;
    EGLContext context;
    EGLSurface surface;
} ska_gl_share;

static void *ska_gl_share_fail(const char *step) {
    char message[160];
    snprintf(message, sizeof message, "no shared GL context: %s failed (EGL error 0x%x)", step, eglGetError());
    ska_log(ANDROID_LOG_WARN, ska_log_tag, message);
    return NULL;
}

void *ska_gl_share_create(void) {
    EGLDisplay display = eglGetCurrentDisplay();
    EGLContext current = eglGetCurrentContext();
    if (display == EGL_NO_DISPLAY || current == EGL_NO_CONTEXT) { return ska_gl_share_fail("finding the current context"); }
    EGLint configID = 0;
    if (!eglQueryContext(display, current, EGL_CONFIG_ID, &configID)) { return ska_gl_share_fail("eglQueryContext"); }
    const EGLint configAttributes[] = { EGL_CONFIG_ID, configID, EGL_NONE };
    EGLConfig config;
    EGLint found = 0;
    if (!eglChooseConfig(display, configAttributes, &config, 1, &found) || found < 1) { return ska_gl_share_fail("eglChooseConfig"); }
    const EGLint contextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLContext context = eglCreateContext(display, config, current, contextAttributes);
    if (context == EGL_NO_CONTEXT) { return ska_gl_share_fail("eglCreateContext"); }
    // No surface where the driver allows it; a pixel of pbuffer where not.
    EGLSurface surface = EGL_NO_SURFACE;
    const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
    if (!extensions || !strstr(extensions, "EGL_KHR_surfaceless_context")) {
        const EGLint surfaceAttributes[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
        surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
        if (surface == EGL_NO_SURFACE) {
            ska_gl_share_fail("eglCreatePbufferSurface");
            eglDestroyContext(display, context);
            return NULL;
        }
    }
    ska_gl_share *share = calloc(1, sizeof(ska_gl_share));
    if (!share) {
        if (surface != EGL_NO_SURFACE) { eglDestroySurface(display, surface); }
        eglDestroyContext(display, context);
        return NULL;
    }
    share->display = display;
    share->context = context;
    share->surface = surface;
    return share;
}

int ska_gl_share_make_current(void *handle) {
    ska_gl_share *share = handle;
    if (!share) { return 0; }
    return eglMakeCurrent(share->display, share->surface, share->surface, share->context) ? 1 : 0;
}

void ska_gl_share_release(void *handle) {
    ska_gl_share *share = handle;
    if (!share) { return; }
    eglMakeCurrent(share->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

void ska_gl_share_destroy(void *handle) {
    ska_gl_share *share = handle;
    if (!share) { return; }
    if (share->surface != EGL_NO_SURFACE) { eglDestroySurface(share->display, share->surface); }
    eglDestroyContext(share->display, share->context);
    free(share);
}

/* ---------------------------------------------------------------------------
   The display: its vsync (AChoreographer) and the size of the window's
   buffers (the hardware scaler). libandroid is opened here rather than
   linked: AChoreographer and ANativeWindow_setFrameRate are newer than the
   API 23 stubs the shell links against.
   ------------------------------------------------------------------------- */

#include <android/looper.h>
#include <android/native_window.h>
#include <time.h>

typedef struct AChoreographer AChoreographer;
typedef void (*ska_frame_cb)(long frameTimeNanos, void *data);
typedef void (*ska_frame_cb64)(int64_t frameTimeNanos, void *data);

static struct {
    int state; /* 0 not tried, 1 running, -1 unavailable */
    AChoreographer *choreographer;
    void (*post)(AChoreographer *, ska_frame_cb, void *);
    void (*post64)(AChoreographer *, ska_frame_cb64, void *);
    int64_t latest;
    int64_t fired;
} ska_vsync;

static void *ska_libandroid(void) {
    static void *library;
    if (!library) { library = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL); }
    return library;
}

static void ska_vsync_post(void);

static void ska_on_vsync64(int64_t nanos, void *data) {
    (void)data;
    if (nanos > ska_vsync.latest) { ska_vsync.latest = nanos; }
    ska_vsync.fired += 1;
    /* Always one waiting, so the next vsync's timestamp is in hand as soon
       as the frame thread looks, however long its frame took. */
    ska_vsync_post();
}

static void ska_on_vsync(long nanos, void *data) { ska_on_vsync64((int64_t)nanos, data); }

static void ska_vsync_post(void) {
    if (ska_vsync.post64) {
        ska_vsync.post64(ska_vsync.choreographer, ska_on_vsync64, NULL);
    } else {
        ska_vsync.post(ska_vsync.choreographer, ska_on_vsync, NULL);
    }
}

bool ska_vsync_start(void) {
    if (ska_vsync.state != 0) { return ska_vsync.state == 1; }
    ska_vsync.state = -1;
    void *library = ska_libandroid();
    if (!library) { return false; }
    AChoreographer *(*instance)(void) = (AChoreographer *(*)(void))dlsym(library, "AChoreographer_getInstance");
    ska_vsync.post64 = (void (*)(AChoreographer *, ska_frame_cb64, void *))dlsym(library, "AChoreographer_postFrameCallback64");
    ska_vsync.post = (void (*)(AChoreographer *, ska_frame_cb, void *))dlsym(library, "AChoreographer_postFrameCallback");
    if (!instance || (!ska_vsync.post64 && !ska_vsync.post)) { return false; }
    /* The choreographer delivers on the calling thread's looper, which a
       native thread has to be given. */
    if (!ALooper_prepare(ALOOPER_PREPARE_ALLOW_NON_CALLBACKS)) { return false; }
    ska_vsync.choreographer = instance();
    if (!ska_vsync.choreographer) { return false; }
    ska_vsync.state = 1;
    ska_vsync_post();
    return true;
}

int64_t ska_monotonic_ns(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000000000LL + now.tv_nsec;
}

int64_t ska_vsync_poll(int timeout_ms) {
    if (ska_vsync.state != 1) { return 0; }
    const int64_t before = ska_vsync.fired;
    /* What's already due, without waiting. */
    while (ALooper_pollOnce(0, NULL, NULL, NULL) == ALOOPER_POLL_CALLBACK) {}
    if (timeout_ms > 0 && ska_vsync.fired == before) {
        const int64_t deadline = ska_monotonic_ns() + (int64_t)timeout_ms * 1000000LL;
        while (ska_vsync.fired == before) {
            const int64_t left = deadline - ska_monotonic_ns();
            if (left <= 0) { break; }
            int wait = (int)((left + 999999) / 1000000);
            if (ALooper_pollOnce(wait, NULL, NULL, NULL) == ALOOPER_POLL_TIMEOUT) { break; }
        }
    }
    return ska_vsync.latest;
}

void *ska_native_window(SDL_Window *window) {
    return SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER, NULL);
}

void *ska_egl_surface(SDL_Window *window) {
    return SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_ANDROID_SURFACE_POINTER, NULL);
}

int ska_native_window_set_buffers(void *window, int width, int height) {
    if (!window) { return -1; }
    ANativeWindow *native = window;
    /* Keep the format SDL chose from the EGL config. */
    return ANativeWindow_setBuffersGeometry(native, width, height, ANativeWindow_getFormat(native));
}

int ska_native_window_set_frame_rate(void *window, float rate) {
    if (!window) { return -1; }
    static int (*setFrameRate)(ANativeWindow *, float, int8_t);
    static int looked;
    if (!looked) {
        looked = 1;
        void *library = ska_libandroid();
        if (library) { setFrameRate = (int (*)(ANativeWindow *, float, int8_t))dlsym(library, "ANativeWindow_setFrameRate"); }
    }
    if (!setFrameRate) { return -1; }
    /* ANATIVEWINDOW_FRAME_RATE_COMPATIBILITY_DEFAULT: a game's rate. */
    return setFrameRate((ANativeWindow *)window, rate, 0);
}

bool ska_surface_size(int *width, int *height) {
    EGLDisplay display = eglGetCurrentDisplay();
    EGLSurface surface = eglGetCurrentSurface(EGL_DRAW);
    if (display == EGL_NO_DISPLAY || surface == EGL_NO_SURFACE) { return false; }
    EGLint w = 0, h = 0;
    if (!eglQuerySurface(display, surface, EGL_WIDTH, &w) || !eglQuerySurface(display, surface, EGL_HEIGHT, &h)) { return false; }
    *width = w;
    *height = h;
    return w > 0 && h > 0;
}
