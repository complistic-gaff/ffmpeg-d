/*
 * copyright (c) 2017 David Bennett <davidbennett@bravevision.com>
 *
 * This is a working encoder and is used to check everything is linked correcty.
 *
 * It converts any progressive input to a x264 + flac stream.
 *
 * To try it out just compile it using:
 *   dub build --config=encode_example
 *
 * Then run it like:
 *   ./encode_example in.mkv out.mkv
 */

import ffmpeg.libavcodec.avcodec;

import ffmpeg.libavformat.avformat;
import ffmpeg.libavformat.avio;

import ffmpeg.libavutil.avutil;
import ffmpeg.libavutil.channel_layout;
import ffmpeg.libavutil.frame;
import ffmpeg.libavutil.mathematics;

import ffmpeg.libswresample.audioconvert;
import ffmpeg.libswresample.swresample;

import ffmpeg.libswscale.swscale;

import std.string : toStringz;

void main(string[] args) {

    // Setup

    string input_filename = args[1];
    string output_filename = args[2];

    av_register_all();



    // ##########################
    //   PART 1:
    //     SET UP THE THE DEMUXER
    // ##########################

    AVFormatContext* input_fmt_ctx;

    AVStream* input_video_stream;
    AVStream* input_audio_stream;

    AVCodec* input_video_codec;
    AVCodec* input_audio_codec;

    AVCodecContext* input_video_codec_ctx;
    AVCodecContext* input_audio_codec_ctx;

    size_t input_video_stream_index;
    size_t input_audio_stream_index;

    // Open the file and init the AVFormatContext
    if(avformat_open_input(&input_fmt_ctx, input_filename.toStringz, null, null) < 0)
        throw new Exception("Could not open source file");

    // Scan the container and fill the AVFormatContext with stream information
    if(avformat_find_stream_info(input_fmt_ctx, null) < 0)
        throw new Exception("Could not find stream information");

    // Writes ffmpeg like input format information to console. Good for debuging.
    av_dump_format(input_fmt_ctx, 0, input_filename.toStringz, 0);

    // Copy some information from the input AVFormatContext
    for(size_t i=0; i<input_fmt_ctx.nb_streams; i++) {

        AVStream* in_stream = input_fmt_ctx.streams[i];

        // Only 1 audio and video stream
        if( in_stream.codecpar.codec_type == AVMediaType.AVMEDIA_TYPE_VIDEO) {
            input_video_stream = in_stream;
            input_video_stream_index = i;
            input_video_codec = avcodec_find_decoder(in_stream.codecpar.codec_id);
            input_video_codec_ctx = avcodec_alloc_context3(input_video_codec);
            if(avcodec_parameters_to_context(input_video_codec_ctx, in_stream.codecpar) < 0)
                throw new Exception("Could not set input context from input video codec parameters");
        } else if(in_stream.codecpar.codec_type == AVMediaType.AVMEDIA_TYPE_AUDIO){
            input_audio_stream = in_stream;
            input_audio_stream_index = i;
            input_audio_codec = avcodec_find_decoder(in_stream.codecpar.codec_id);
            input_audio_codec_ctx = avcodec_alloc_context3(input_audio_codec);
            if(avcodec_parameters_to_context(input_audio_codec_ctx, in_stream.codecpar) < 0)
                throw new Exception("Could not set input context from input audio codec parameters");
        } else continue;

    }

    // Open the decoders, we do this here as it will set some of the codec context
    if(avcodec_open2(input_video_codec_ctx, input_video_codec, null) < 0)
        throw new Exception("Could not open input video codec");

    if(avcodec_open2(input_audio_codec_ctx, input_audio_codec, null) < 0)
        throw new Exception("Could not open input audio codec");



    // ##########################
    //   PART 2:
    //     SET UP THE THE MUXER
    // ##########################

    AVFormatContext* output_fmt_ctx;

    // Create a new output AVFormatContext with infomation with the filename
    if(avformat_alloc_output_context2(&output_fmt_ctx, null, null, output_filename.toStringz) < 0)
        throw new Exception("Failed to create output context");



    // ##########################
    //   PART 3:
    //     SETUP THE OUTPUT CODECS (hard coded to h264 and FLAC)
    // ##########################

    AVCodec* output_video_codec;
    AVCodec* output_audio_codec;

    AVCodecContext* output_video_codec_ctx;
    AVCodecContext* output_audio_codec_ctx;

    // VIDEO CODEC

    output_fmt_ctx.oformat.video_codec = AVCodecID.AV_CODEC_ID_H264;

    // Init the video AVCodec
    output_video_codec = avcodec_find_encoder(AVCodecID.AV_CODEC_ID_H264);

    if(!output_video_codec)
        throw new Exception("Could not find h264 codec");

    // Create a new AVCodecContext for the codec
    output_video_codec_ctx   = avcodec_alloc_context3(output_video_codec);

    // Cody the resolution from the input
    output_video_codec_ctx.width         = input_video_codec_ctx.width;
    output_video_codec_ctx.height        = input_video_codec_ctx.height;
    output_video_codec_ctx.pix_fmt       = input_video_codec_ctx.pix_fmt;

    // Set the codec time based on the avg_frame_rate from the input
    output_video_codec_ctx.time_base.num = input_video_stream.avg_frame_rate.den;
    output_video_codec_ctx.time_base.den = input_video_stream.avg_frame_rate.num;

    // Force a max gop of 240
    output_video_codec_ctx.gop_size      = 240;

    // Setup params for h264
    import ffmpeg.libavutil.opt : av_opt_set;
    av_opt_set(output_video_codec_ctx.priv_data, "crf", "12", 0);
    av_opt_set(output_video_codec_ctx.priv_data, "preset", "veryfast", 0);
    av_opt_set(output_video_codec_ctx.priv_data, "tune", "film", 0);
    av_opt_set(output_video_codec_ctx.priv_data, "threads", "6", 0);
    av_opt_set(output_video_codec_ctx.priv_data, "x264opts", "threads=6", 0);

    // Some containers need information copied from the codec, if so set the flag on the codec context.
    if(output_fmt_ctx.oformat.flags & AVFMT_GLOBALHEADER) // 0x0040
        output_video_codec_ctx.flags |= AV_CODEC_FLAG_GLOBAL_HEADER; // (1 << 22)

    // Open the video codec
    if(avcodec_open2(output_video_codec_ctx, output_video_codec, null) < 0)
        throw new Exception("Could not open output video codec");

    // AUDIO CODEC

    output_fmt_ctx.oformat.audio_codec = AVCodecID.AV_CODEC_ID_FLAC;

    // Init the audio codex
    output_audio_codec = avcodec_find_encoder(AVCodecID.AV_CODEC_ID_FLAC);

    if(!output_audio_codec)
        throw new Exception("Could not find flac codec");

    output_audio_codec_ctx                  = avcodec_alloc_context3(output_audio_codec);

    // Set the time_base to the sample rate
    output_audio_codec_ctx.time_base.num    = 1;
    output_audio_codec_ctx.time_base.den    = input_audio_codec_ctx.sample_rate;

    output_audio_codec_ctx.channels         = input_audio_codec_ctx.channels;
    output_audio_codec_ctx.channel_layout   = av_get_default_channel_layout(input_audio_codec_ctx.channels);
    output_audio_codec_ctx.sample_rate      = input_audio_codec_ctx.sample_rate;
    output_audio_codec_ctx.sample_fmt       = output_audio_codec.sample_fmts[0];

    // Some containers need information copied from the codec, if so set the flag on the codec context.
    if(output_fmt_ctx.oformat.flags & 0x0040)
        output_audio_codec_ctx.flags |= AV_CODEC_FLAG_GLOBAL_HEADER; //(1 << 22)

    // Open the video codec
    if(avcodec_open2(output_audio_codec_ctx, output_audio_codec, null) < 0)
        throw new Exception("Could not open output audio codec");



    // ##########################
    //   PART 4:
    //     SETUP THE OUTPUT STREAMS
    // ##########################

    AVStream* output_video_stream;
    AVStream* output_audio_stream;

    int output_video_stream_index;
    int output_audio_stream_index;

    // VIDEO STREAM

    // Init the video stream
    output_video_stream = avformat_new_stream(output_fmt_ctx, output_video_codec);

    if(!output_video_stream)
        throw new Exception("Could not create video stream");

    // Copy the stream avg_frame_rate from the input
    output_video_stream.avg_frame_rate.num = input_video_stream.avg_frame_rate.num;
    output_video_stream.avg_frame_rate.den = input_video_stream.avg_frame_rate.den;

    // Copy the stream sample_aspect_ratio from the input
    output_video_stream.sample_aspect_ratio.num = input_video_stream.sample_aspect_ratio.num;
    output_video_stream.sample_aspect_ratio.den = input_video_stream.sample_aspect_ratio.den;

    output_video_stream_index = output_video_stream.index;

    // Set the video stream AVCodecParameters based on the codec context
    if(avcodec_parameters_from_context(output_video_stream.codecpar, output_video_codec_ctx) < 0)
        throw new Exception("Could not open set stream codec parameters from video codec context");

    // Set the stream time base to 1/10000 of a second
    output_video_stream.time_base.num    = 1;
    output_video_stream.time_base.den    = 10_000;

    // AUDIO STREAM

    // Init the audio stream
    output_audio_stream = avformat_new_stream(output_fmt_ctx, output_audio_codec);

    if(!output_audio_stream)
        throw new Exception("Could not create audio stream");

    output_audio_stream_index               = output_audio_stream.index;

    // Set the video stream AVCodecParameters based on the codec context
    if(avcodec_parameters_from_context(output_audio_stream.codecpar, output_audio_codec_ctx) < 0)
        throw new Exception("Could not open set stream codec parameters from audio codec context");

    // Set the stream time base to 1/10000 of a second
    output_audio_stream.time_base.num    = 1;
    output_audio_stream.time_base.den    = 10_000;


    // Writes ffmpeg like output format information to console. Good for debuging.
    av_dump_format(output_fmt_ctx, 0, output_filename.toStringz, 1);



    // ##########################
    //   PART 5:
    //     READ PACKETS FROM DEMUXER, ENCODE AND WRITE TO MUXER
    // ##########################

    AVFrame* input_video_frame = av_frame_alloc();
    AVFrame* input_audio_frame = av_frame_alloc();

    // Setup video scaler (handles resolution and pixel format conversions) see libswscale
    SwsContext* encode_sws_ctx = sws_getContext(
        input_video_codec_ctx.width,  input_video_codec_ctx.height,  input_video_codec_ctx.pix_fmt,
        output_video_codec_ctx.width, output_video_codec_ctx.height, output_video_codec_ctx.pix_fmt,
        SWS_FAST_BILINEAR, null, null, null
    );

    // Setup audio resampler (handles channel, rate and format conversions) see libswresample
    SwrContext* encode_swr_ctx = swr_alloc_set_opts(null,
        output_audio_codec_ctx.channel_layout, output_audio_codec_ctx.sample_fmt, input_audio_codec_ctx.sample_rate,
        input_audio_codec_ctx.channel_layout,  input_audio_codec_ctx.sample_fmt,  output_audio_codec_ctx.sample_rate,
        0, null
    );

    // Create a tempory video frame to write the resized data to.
    AVFrame* output_video_frame = av_frame_alloc();
    output_video_frame.width   = output_video_codec_ctx.width;
    output_video_frame.height  = output_video_codec_ctx.height;
    output_video_frame.format  = output_video_codec_ctx.pix_fmt;
    output_video_frame.pts     = 0;

    if(av_frame_get_buffer(output_video_frame, 32) < 0)
        throw new Exception("Could not allocate videoframe data.");

    // Create a tempory audio frame to write the resampled data to.
    AVFrame* output_audio_frame = av_frame_alloc();
    output_audio_frame.pts             = 0;
    output_audio_frame.nb_samples      = output_audio_codec_ctx.sample_rate;
    output_audio_frame.channels        = output_audio_codec_ctx.channels;
    output_audio_frame.channel_layout  = output_audio_codec_ctx.channel_layout;
    output_audio_frame.format          = output_audio_codec_ctx.sample_fmt;
    output_audio_frame.sample_rate     = output_audio_codec_ctx.sample_rate;

    if(av_frame_get_buffer(output_audio_frame, 0) < 0)
        throw new Exception("Could not allocate audio frame data.");

    // Init the packets to and from the muxer
    AVPacket* input_packet = av_packet_alloc();
    AVPacket* output_video_packet = av_packet_alloc();
    AVPacket* output_audio_packet = av_packet_alloc();

    long video_pts = 0;
    long audio_pts = 0;

    // Open the output file
    if(!(output_fmt_ctx.oformat.flags & AVFMT_NOFILE)) // 0x0001
        if(avio_open(&output_fmt_ctx.pb, output_filename.toStringz, AVIO_FLAG_WRITE) < 0)
            throw new Exception("Could not open output file");

    // Write the container header to the output file
    if(avformat_write_header(output_fmt_ctx, null) < 0)
        throw new Exception("Error opening output file.");

    bool reading_input = true;

    // Loop over all the packets in the input container
    while(reading_input) {

        if(av_read_frame(input_fmt_ctx, input_packet) >= 0) {
            // Read packet from the input file
            if(input_packet.stream_index == input_video_stream_index) {
                // Send the input packet to the video decoder
                if(avcodec_send_packet(input_video_codec_ctx, input_packet) < 0)
                    throw new Exception("Error when decoding video packet");
            } else if(input_packet.stream_index == input_audio_stream_index) {
                // Send the input packet to the audio decoder
                if(avcodec_send_packet(input_audio_codec_ctx, input_packet) < 0)
                    throw new Exception("Error when decoding audio packet");
            }
        } else {
            // Stoped reading input, change to decoders to flush mode to get all remaining frames out of the decoders
            reading_input = false;
            // Send null to put decoders into drain mode
            avcodec_send_packet(input_video_codec_ctx, null);
            avcodec_send_packet(input_audio_codec_ctx, null);
        }


        // Check for decoded video frames
        while(avcodec_receive_frame(input_video_codec_ctx, input_video_frame) == 0) {
            // Scale the input frame to the output frame size
            sws_scale(encode_sws_ctx,
                input_video_frame.data.ptr,  input_video_frame.linesize.ptr, 0, input_video_frame.height,
                output_video_frame.data.ptr, output_video_frame.linesize.ptr
            );

            output_video_frame.pts = video_pts;
            video_pts += 1;

            // Send decoded video frame to the encoder
            if(avcodec_send_frame(output_video_codec_ctx, output_video_frame) < 0)
                throw new Exception("Error when sending video frame to encoder");

        }

        // Check for decoded audio frames
        while(avcodec_receive_frame(input_audio_codec_ctx, input_audio_frame) == 0) {

            // Convert the audio sample rate and chanel layout
            swr_convert_frame(encode_swr_ctx, output_audio_frame, input_audio_frame);

            // Set the pts and offset the next output frame by the number of samples
            output_audio_frame.pts = audio_pts;
            audio_pts += output_audio_frame.nb_samples;

            // Send decoded audio frame to the encoder
            if(avcodec_send_frame(output_audio_codec_ctx, output_audio_frame) < 0)
                throw new Exception("Error when sending audio frame to encoder");

        }

        if(!reading_input) {
            // Finished reading from input and all frames are in the encoders so put the encoders in flush mode!
            avcodec_send_frame(output_video_codec_ctx, null);
            avcodec_send_frame(output_audio_codec_ctx, null);
        }

        // Check for encoded video frames
        while(video_pts > 0 && avcodec_receive_packet(output_video_codec_ctx, output_video_packet) == 0) {

            // Set video stream index
            output_video_packet.stream_index = output_video_stream_index;

            // Rescale codec time to stream time
            av_packet_rescale_ts(output_video_packet, output_video_codec_ctx.time_base, output_video_stream.time_base);

            // Write packet to stream for muxing
            if(av_interleaved_write_frame(output_fmt_ctx, output_video_packet) < 0)
                throw new Exception("Could not write video frame");

            av_packet_unref(output_video_packet);

        }

        // Check for encoded audio frames
        while(audio_pts > 0 && avcodec_receive_packet(output_audio_codec_ctx, output_audio_packet) == 0) {

            // set audio stream index
            output_audio_packet.stream_index = output_audio_stream_index;

            // Rescale codec time to stream time
            av_packet_rescale_ts(output_audio_packet, output_audio_codec_ctx.time_base, output_audio_stream.time_base);

            // HACK!!! This is needed because some audio codecs update internal stream data...
            // See https://www.ffmpeg.org/doxygen/3.2/ffmpeg_8c_source.html#l00800
            if(avcodec_parameters_from_context(output_audio_stream.codecpar, output_audio_codec_ctx) < 0)
                throw new Exception("Could not open set stream codec parameters from audio codec context");

            // Write packet to stream for muxing
            if(av_interleaved_write_frame(output_fmt_ctx, output_audio_packet) < 0)
                throw new Exception("Could not write audio frame");

            av_packet_unref(output_audio_packet);

        }

        // Clean up the input packet
        av_packet_unref(input_packet);

    }


    // ##########################
    //   PART 6:
    //     FINISH WRITING TO MUXER
    // ##########################

    // Close the input file as were not using it anymore
    avformat_close_input(&input_fmt_ctx);

    // Write the container trailer
    if(av_write_trailer(output_fmt_ctx) < 0)
        throw new Exception("Could not write the container trailer");

    // Close the output file if needed
    if(output_fmt_ctx && !(output_fmt_ctx.oformat.flags & AVFMT_NOFILE))
        avio_closep(&output_fmt_ctx.pb);



    // ##########################
    //   PART 7:
    //     CLEAN UP !!!
    // ##########################

    // Close and free the output codec contexts
    avcodec_close(output_video_codec_ctx);
    avcodec_close(output_audio_codec_ctx);

    // Free the tempory input and output frames
    av_frame_free(&input_video_frame);
    av_frame_free(&input_audio_frame);
    av_frame_free(&output_video_frame);
    av_frame_free(&output_audio_frame);

    // Free the scaler and resampler contexts
    sws_freeContext(encode_sws_ctx);
    swr_free(&encode_swr_ctx);

    // Free input and output contexts
    avformat_free_context(input_fmt_ctx);
    avformat_free_context(output_fmt_ctx);

}
