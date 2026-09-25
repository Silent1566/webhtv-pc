#include <jni.h>
#include <mpv/client.h>
#include <stdint.h>
#include <stdio.h>

static jfieldID handle_field(JNIEnv *env, jobject self) {
    jclass type = (*env)->GetObjectClass(env, self);
    return (*env)->GetFieldID(env, type, "handle", "J");
}

static mpv_handle *get_handle(JNIEnv *env, jobject self) {
    return (mpv_handle *)(intptr_t)(*env)->GetLongField(env, self, handle_field(env, self));
}

static void throw_state(JNIEnv *env, const char *message) {
    jclass type = (*env)->FindClass(env, "java/lang/IllegalStateException");
    (*env)->ThrowNew(env, type, message);
}

JNIEXPORT jlong JNICALL Java_local_webhtv_phase0_LibMpv_create(JNIEnv *env, jobject self) {
    (void)env;
    (void)self;
    mpv_handle *handle = mpv_create();
    if (handle == NULL) return 0;
    mpv_set_option_string(handle, "terminal", "no");
    mpv_set_option_string(handle, "audio-display", "no");
    if (mpv_initialize(handle) < 0) {
        mpv_terminate_destroy(handle);
        return 0;
    }
    return (jlong)(intptr_t)handle;
}

JNIEXPORT void JNICALL Java_local_webhtv_phase0_LibMpv_destroy(JNIEnv *env, jobject self, jlong value) {
    (void)env;
    (void)self;
    mpv_handle *handle = (mpv_handle *)(intptr_t)value;
    if (handle != NULL) mpv_terminate_destroy(handle);
}

JNIEXPORT jstring JNICALL Java_local_webhtv_phase0_LibMpv_clientVersion(JNIEnv *env, jobject self) {
    (void)self;
    unsigned long version = mpv_client_api_version();
    char text[32];
    snprintf(text, sizeof(text), "%lu.%lu", version >> 16, version & 0xffff);
    return (*env)->NewStringUTF(env, text);
}

JNIEXPORT void JNICALL Java_local_webhtv_phase0_LibMpv_load(JNIEnv *env, jobject self, jstring url, jstring referer, jstring user_agent) {
    mpv_handle *handle = get_handle(env, self);
    if (handle == NULL) { throw_state(env, "libmpv 已关闭"); return; }
    const char *url_text = (*env)->GetStringUTFChars(env, url, NULL);
    const char *referer_text = (*env)->GetStringUTFChars(env, referer, NULL);
    const char *agent_text = (*env)->GetStringUTFChars(env, user_agent, NULL);
    if (referer_text[0] != '\0') mpv_set_property_string(handle, "referrer", referer_text);
    if (agent_text[0] != '\0') mpv_set_property_string(handle, "user-agent", agent_text);
    const char *command[] = {"loadfile", url_text, "replace", NULL};
    int result = mpv_command(handle, command);
    (*env)->ReleaseStringUTFChars(env, url, url_text);
    (*env)->ReleaseStringUTFChars(env, referer, referer_text);
    (*env)->ReleaseStringUTFChars(env, user_agent, agent_text);
    if (result < 0) throw_state(env, mpv_error_string(result));
}

JNIEXPORT void JNICALL Java_local_webhtv_phase0_LibMpv_seek(JNIEnv *env, jobject self, jdouble seconds) {
    mpv_handle *handle = get_handle(env, self);
    if (handle == NULL) { throw_state(env, "libmpv 已关闭"); return; }
    char value[64];
    snprintf(value, sizeof(value), "%.3f", seconds);
    const char *command[] = {"seek", value, "absolute+exact", NULL};
    int result = mpv_command(handle, command);
    if (result < 0) throw_state(env, mpv_error_string(result));
}

JNIEXPORT jdouble JNICALL Java_local_webhtv_phase0_LibMpv_playbackTime(JNIEnv *env, jobject self) {
    mpv_handle *handle = get_handle(env, self);
    if (handle == NULL) { throw_state(env, "libmpv 已关闭"); return 0.0; }
    double seconds = 0.0;
    int result = mpv_get_property(handle, "playback-time", MPV_FORMAT_DOUBLE, &seconds);
    if (result < 0) { throw_state(env, mpv_error_string(result)); return 0.0; }
    return seconds;
}

JNIEXPORT void JNICALL Java_local_webhtv_phase0_LibMpv_setFullscreen(JNIEnv *env, jobject self, jboolean enabled) {
    mpv_handle *handle = get_handle(env, self);
    if (handle == NULL) { throw_state(env, "libmpv 已关闭"); return; }
    int flag = enabled ? 1 : 0;
    int result = mpv_set_property(handle, "fullscreen", MPV_FORMAT_FLAG, &flag);
    if (result < 0) throw_state(env, mpv_error_string(result));
}

JNIEXPORT jstring JNICALL Java_local_webhtv_phase0_LibMpv_waitForEvent(JNIEnv *env, jobject self, jdouble timeout_seconds) {
    mpv_handle *handle = get_handle(env, self);
    if (handle == NULL) { throw_state(env, "libmpv 已关闭"); return NULL; }
    mpv_event *event = mpv_wait_event(handle, timeout_seconds);
    const char *name = mpv_event_name(event->event_id);
    return (*env)->NewStringUTF(env, name == NULL ? "unknown" : name);
}


JNIEXPORT jstring JNICALL Java_local_webhtv_phase0_LibMpv_waitForPlaybackResult(JNIEnv *env, jobject self, jdouble timeout_seconds) {
    mpv_handle *handle = get_handle(env, self);
    if (handle == NULL) { throw_state(env, "libmpv 已关闭"); return NULL; }

    double remaining = timeout_seconds;
    while (remaining > 0.0) {
        double slice = remaining > 0.25 ? 0.25 : remaining;
        mpv_event *event = mpv_wait_event(handle, slice);
        remaining -= slice;
        if (event->event_id == MPV_EVENT_FILE_LOADED) {
            return (*env)->NewStringUTF(env, "file-loaded");
        }
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = (mpv_event_end_file *)event->data;
            if (end != NULL && end->reason == MPV_END_FILE_REASON_ERROR) {
                char text[256];
                snprintf(text, sizeof(text), "error:%s", mpv_error_string(end->error));
                return (*env)->NewStringUTF(env, text);
            }
            return (*env)->NewStringUTF(env, "end-file");
        }
        if (event->event_id == MPV_EVENT_SHUTDOWN) {
            return (*env)->NewStringUTF(env, "shutdown");
        }
    }
    return (*env)->NewStringUTF(env, "timeout");
}
