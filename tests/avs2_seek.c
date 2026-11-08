// Usage: avs2-seek /path/to/short.avs2 (a complete, short elementary stream).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/md5.h>
#include <libavutil/pixdesc.h>

typedef struct Signature {
    unsigned char md5[16];
    int width, height, format, flags, range, primaries, transfer, matrix;
} Signature;

static Signature reference[512];
static int reference_count;

static void check(int ret, const char *operation)
{
    if (ret < 0) {
        char error[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(ret, error, sizeof(error));
        fprintf(stderr, "%s: %s\n", operation, error);
        exit(1);
    }
}

static void record(AVFrame *frame, int pass, int index)
{
    Signature sig = {0};
    struct AVMD5 *md5 = av_md5_alloc();
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(frame->format);
    if (!md5 || !desc || index >= 512)
        exit(1);
    av_md5_init(md5);
    for (int plane = 0; plane < 3; plane++) {
        int height = plane ? AV_CEIL_RSHIFT(frame->height, desc->log2_chroma_h) : frame->height;
        int bytes = av_image_get_linesize(frame->format, frame->width, plane);
        for (int y = 0; y < height; y++)
            av_md5_update(md5, frame->data[plane] + y * frame->linesize[plane], bytes);
    }
    av_md5_final(md5, sig.md5);
    av_free(md5);
    sig.width = frame->width;
    sig.height = frame->height;
    sig.format = frame->format;
    sig.flags = frame->flags;
    sig.range = frame->color_range;
    sig.primaries = frame->color_primaries;
    sig.transfer = frame->color_trc;
    sig.matrix = frame->colorspace;
    if (pass == 0)
        reference[index] = sig;
    else if (index >= reference_count || memcmp(&sig, &reference[index], sizeof(sig))) {
        fprintf(stderr, "Frame/metadata mismatch: pass=%d frame=%d\n", pass, index);
        exit(1);
    }
}

static int decode(AVFormatContext *input, AVCodecContext *decoder, int stream, int pass, int limit)
{
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int count = 0, done = 0;
    if (!packet || !frame)
        exit(1);
    while (!done) {
        int ret = av_read_frame(input, packet);
        if (ret < 0 && ret != AVERROR_EOF)
            check(ret, "read");
        if (ret >= 0 && packet->stream_index != stream) {
            av_packet_unref(packet);
            continue;
        }
        done = ret == AVERROR_EOF;
        check(avcodec_send_packet(decoder, done ? NULL : packet), "send");
        av_packet_unref(packet);
        while ((ret = avcodec_receive_frame(decoder, frame)) >= 0) {
            record(frame, pass, count++);
            av_frame_unref(frame);
            if (limit && count == limit)
                goto finished;
        }
        if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF)
            check(ret, "receive");
    }
finished:
    av_packet_free(&packet);
    av_frame_free(&frame);
    return count;
}

static void rewind_decoder(AVFormatContext *input, AVCodecContext *decoder)
{
    check(av_seek_frame(input, -1, 0, AVSEEK_FLAG_BYTE), "seek to start");
    avcodec_flush_buffers(decoder);
    // Flush is safe even before another packet has been submitted.
    avcodec_flush_buffers(decoder);
}

int main(int argc, char **argv)
{
    AVFormatContext *input = NULL;
    AVCodecContext *decoder;
    const AVCodec *codec = avcodec_find_decoder_by_name("libdavs2");
    if (argc != 2 || !codec)
        return 1;
    av_log_set_level(AV_LOG_ERROR);
    check(avformat_open_input(&input, argv[1], NULL, NULL), "open input");
    check(avformat_find_stream_info(input, NULL), "probe");
    int stream = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    check(stream, "video stream");
    decoder = avcodec_alloc_context3(codec);
    if (!decoder)
        return 1;
    check(avcodec_parameters_to_context(decoder, input->streams[stream]->codecpar), "parameters");
    decoder->thread_count = 2;
    check(avcodec_open2(decoder, codec, NULL), "open decoder");
    reference_count = decode(input, decoder, stream, 0, 0);
    if (reference_count < 16)
        return 1;
    rewind_decoder(input, decoder);
    if (decode(input, decoder, stream, 1, 12) != 12)
        return 1;
    rewind_decoder(input, decoder); // Discard in-flight/delayed references.
    for (int pass = 2; pass <= 3; pass++) {
        if (decode(input, decoder, stream, pass, 0) != reference_count)
            return 1;
        rewind_decoder(input, decoder); // Reset after EOF draining as well.
    }
    avcodec_free_context(&decoder);
    avformat_close_input(&input);
    printf("PASS: %d frames; repeated EOF and mid-stream seeks preserve pixels and metadata\n", reference_count);
    return 0;
}
