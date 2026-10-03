// Exercise display ICC selection and live HDR/SDR transitions on gpu-next.
// Build with the custom bundle's headers, libmpv, and -framework OpenGL.
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

#define WIDTH 640
#define HEIGHT 360
#define PIXEL_BYTES (WIDTH * HEIGHT * 4)

static mpv_handle *mpv;
static mpv_render_context *renderer;
static GLuint framebuffer;
static bool loaded;
static int rendered;
static const char *output_directory;

static void check(int result, const char *operation)
{
    if (result < 0) {
        fprintf(stderr, "%s: %s\n", operation, mpv_error_string(result));
        exit(1);
    }
}

static void *get_proc_address(void *context, const char *name)
{
    (void)context;
    return dlsym(RTLD_DEFAULT, name);
}

static void pump(void)
{
    mpv_event *event = mpv_wait_event(mpv, 0.01);
    if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
        mpv_event_log_message *log = event->data;
        fprintf(stderr, "[%s] %s", log->prefix, log->text);
    } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
        loaded = true;
    } else if (event->event_id == MPV_EVENT_END_FILE) {
        fprintf(stderr, "File ended during ICC validation\n");
        exit(1);
    } else if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
        check(event->error, "loadfile");
    }
    if (mpv_render_context_update(renderer) & MPV_RENDER_UPDATE_FRAME) {
        mpv_opengl_fbo fbo = { .fbo = (int)framebuffer, .w = WIDTH, .h = HEIGHT };
        int flip = 1;
        mpv_render_param params[] = {
            { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
            { MPV_RENDER_PARAM_FLIP_Y, &flip },
            { 0 },
        };
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        check(mpv_render_context_render(renderer, params), "render");
        mpv_render_context_report_swap(renderer);
        rendered++;
    }
}

static void set_option(const char *name, const char *value)
{
    check(mpv_set_property_string(mpv, name, value), name);
}

static void set_profile(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file) {
        perror(path);
        exit(1);
    }
    if (fseek(file, 0, SEEK_END))
        exit(1);
    long length = ftell(file);
    if (length <= 0 || length > 100000000 || fseek(file, 0, SEEK_SET))
        exit(1);
    unsigned char *data = malloc((size_t)length);
    if (!data || fread(data, 1, (size_t)length, file) != (size_t)length)
        exit(1);
    fclose(file);
    mpv_byte_array bytes = { .data = data, .size = (size_t)length };
    mpv_render_param param = { MPV_RENDER_PARAM_ICC_PROFILE, &bytes };
    check(mpv_render_context_set_parameter(renderer, param), "render ICC profile");
    free(data);
}

static void snapshot(const char *name, unsigned char *pixels)
{
    // Allow the video thread to process property changes and request a redraw.
    for (int i = 0; i < 100; i++)
        pump();
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glReadPixels(0, 0, WIDTH, HEIGHT, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    char path[4096];
    snprintf(path, sizeof(path), "%s/%s.rgba", output_directory, name);
    FILE *file = fopen(path, "wb");
    if (!file || fwrite(pixels, 1, PIXEL_BYTES, file) != PIXEL_BYTES)
        exit(1);
    fclose(file);
}

static void compare(const char *name, const unsigned char *a,
                    const unsigned char *b, bool equal)
{
    bool identical = memcmp(a, b, PIXEL_BYTES) == 0;
    printf("%s: %s\n", name, identical == equal ? "PASS" : "FAIL");
    if (identical != equal)
        exit(1);
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "Usage: %s HDR-sample display-p3.icc srgb.icc output-directory\n", argv[0]);
        return 1;
    }
    output_directory = argv[4];
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatObj format;
    CGLContextObj context;
    GLint count;
    if (CGLChoosePixelFormat(attributes, &format, &count) != kCGLNoError ||
        CGLCreateContext(format, NULL, &context) != kCGLNoError ||
        CGLSetCurrentContext(context) != kCGLNoError)
        return 1;
    CGLDestroyPixelFormat(format);
    mpv = mpv_create();
    if (!mpv)
        return 1;
    check(mpv_request_log_messages(mpv, "warn"), "logging");
    check(mpv_set_option_string(mpv, "vo", "libmpv"), "vo");
    check(mpv_set_option_string(mpv, "ao", "null"), "ao");
    check(mpv_set_option_string(mpv, "pause", "yes"), "pause");
    check(mpv_set_option_string(mpv, "hwdec", "videotoolbox"), "hwdec");
    check(mpv_set_option_string(mpv, "icc-profile-auto", "no"), "icc-profile-auto");
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
    check(mpv_render_context_create(&renderer, mpv, params), "gpu-next renderer");
    GLuint texture;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, WIDTH, HEIGHT, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        return 1;
    const char *load[] = { "loadfile", argv[1], NULL };
    check(mpv_command_async(mpv, 1, load), "loadfile");
    time_t deadline = time(NULL) + 90;
    while ((!loaded || !rendered) && time(NULL) < deadline)
        pump();
    if (!loaded || !rendered)
        return 1;

    unsigned char *none = malloc(PIXEL_BYTES), *p3 = malloc(PIXEL_BYTES);
    unsigned char *srgb = malloc(PIXEL_BYTES), *current = malloc(PIXEL_BYTES);
    if (!none || !p3 || !srgb || !current)
        return 1;
    snapshot("none", none);
    set_profile(argv[2]);
    set_option("icc-profile-auto", "yes");
    snapshot("auto-p3", p3);
    compare("P3 profile changes RGB output", none, p3, false);
    set_option("icc-profile-auto", "no");
    set_option("icc-profile", argv[2]);
    snapshot("file-p3", current);
    compare("file P3 matches Render API P3", p3, current, true);
    set_profile(argv[3]);
    set_option("icc-profile-auto", "yes");
    snapshot("file-precedence", current);
    compare("explicit file overrides auto sRGB", p3, current, true);
    set_option("icc-profile", "");
    snapshot("auto-srgb", srgb);
    compare("clearing file restores latest auto profile", p3, srgb, false);
    set_option("icc-profile", argv[3]);
    snapshot("file-srgb", current);
    compare("file sRGB matches Render API sRGB", srgb, current, true);
    set_option("icc-profile", argv[2]);
    snapshot("changed-file", current);
    compare("changing file reloads P3", p3, current, true);
    set_option("icc-profile-auto", "no");
    set_option("icc-profile", "");
    snapshot("disabled", current);
    compare("clearing file and disabling auto restores no ICC", none, current, true);
    set_option("target-prim", "bt.2020");
    set_option("target-trc", "pq");
    snapshot("hdr", current);
    compare("HDR target differs from SDR", none, current, false);
    set_option("target-prim", "auto");
    set_option("target-trc", "auto");
    set_option("icc-profile", argv[2]);
    snapshot("hdr-to-sdr", current);
    compare("HDR to SDR restores P3 output", p3, current, true);
    set_option("icc-profile", "/nonexistent/libmpv-icc-validation.icc");
    snapshot("missing-file", current);
    compare("missing file clears previous ICC", none, current, true);
    // This existing C source is intentionally not an ICC file.
    set_option("icc-profile", __FILE__);
    snapshot("invalid-file", current);
    compare("invalid file clears previous ICC", none, current, true);
    set_option("icc-profile", argv[2]);
    snapshot("recovered", current);
    compare("valid file recovers after failures", p3, current, true);

    free(none); free(p3); free(srgb); free(current);
    mpv_render_context_free(renderer);
    mpv_terminate_destroy(mpv);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    return 0;
}
