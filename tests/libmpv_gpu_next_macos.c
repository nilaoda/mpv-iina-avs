// Render a real file through IINA's OpenGL/libmpv gpu-next path and capture it.
// Build with the bundle's headers, libmpv, and -framework OpenGL.
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void *get_proc_address(void *context, const char *name)
{
    (void)context;
    return dlsym(RTLD_DEFAULT, name);
}

static void check(int result, const char *operation)
{
    if (result < 0) {
        fprintf(stderr, "%s: %s\n", operation, mpv_error_string(result));
        exit(1);
    }
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "Usage: %s sample-file screenshot-prefix\n", argv[0]);
        return 1;
    }
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatObj format;
    GLint count;
    CGLContextObj context;
    if (CGLChoosePixelFormat(attributes, &format, &count) != kCGLNoError ||
        CGLCreateContext(format, NULL, &context) != kCGLNoError ||
        CGLSetCurrentContext(context) != kCGLNoError) {
        fprintf(stderr, "Unable to create a macOS OpenGL context\n");
        return 1;
    }
    CGLDestroyPixelFormat(format);
    mpv_handle *mpv = mpv_create();
    if (!mpv)
        return 1;
    check(mpv_request_log_messages(mpv, "warn"), "logging");
    check(mpv_set_option_string(mpv, "vo", "libmpv"), "vo");
    check(mpv_set_option_string(mpv, "ao", "null"), "ao");
    check(mpv_set_option_string(mpv, "pause", "yes"), "pause");
    check(mpv_set_option_string(mpv, "hwdec", "videotoolbox"), "hwdec");
    check(mpv_set_option_string(mpv, "screenshot-sw", "no"), "screenshot-sw");
    check(mpv_set_option_string(mpv, "screenshot-avif-encoder", "libsvtav1"), "avif encoder");
    check(mpv_set_option_string(mpv, "screenshot-avif-opts", "svtav1-params=avif=1"), "avif options");
    check(mpv_initialize(mpv), "initialize");
    mpv_opengl_init_params gl = { .get_proc_address = get_proc_address };
    int advanced = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_BACKEND, "gpu-next" },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl },
        { MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced },
        { 0 },
    };
    mpv_render_context *renderer;
    check(mpv_render_context_create(&renderer, mpv, params), "gpu-next renderer");
    GLuint texture, framebuffer;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 640, 360, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        return 1;
    mpv_opengl_fbo fbo = { .fbo = (int)framebuffer, .w = 640, .h = 360 };
    int flip = 1;
    mpv_render_param draw[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { 0 },
    };
    const char *load[] = { "loadfile", argv[1], NULL };
    check(mpv_command_async(mpv, 1, load), "loadfile");
    const char *extensions[] = { "png", "jxl", "avif" };
    int rendered = 0, captures = 0;
    bool requested = false, loaded = false;
    time_t deadline = time(NULL) + 90;
    while (time(NULL) < deadline && captures < 3) {
        mpv_event *event = mpv_wait_event(mpv, 0.01);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = event->data;
            fprintf(stderr, "[%s] %s", log->prefix, log->text);
        } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
            loaded = true;
        } else if (event->event_id == MPV_EVENT_END_FILE) {
            fprintf(stderr, "File ended before captures completed\n");
            return 1;
        } else if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
            check(event->error, "async command");
            if (event->reply_userdata >= 10)
                captures++;
        }
        if (mpv_render_context_update(renderer) & MPV_RENDER_UPDATE_FRAME) {
            glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
            check(mpv_render_context_render(renderer, draw), "render");
            mpv_render_context_report_swap(renderer);
            rendered++;
        }
        if (loaded && rendered && !requested) {
            for (int i = 0; i < 3; i++) {
                char filename[4096];
                snprintf(filename, sizeof(filename), "%s.%s", argv[2], extensions[i]);
                const char *capture[] = { "screenshot-to-file", filename, "video", NULL };
                check(mpv_command_async(mpv, 10 + i, capture), "capture");
            }
            requested = true;
        }
    }
    char *hardware = mpv_get_property_string(mpv, "hwdec-current");
    printf("Rendered %d frames with gpu-next; %d screenshots; hwdec=%s\n",
           rendered, captures, hardware ? hardware : "unknown");
    mpv_free(hardware);
    mpv_render_context_free(renderer);
    mpv_terminate_destroy(mpv);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    return rendered && captures == 3 ? 0 : 1;
}
