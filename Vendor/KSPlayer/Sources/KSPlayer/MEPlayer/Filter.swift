//
//  Filter.swift
//  KSPlayer
//
//  Created by kintan on 2021/8/7.
//

import Foundation
import FFmpegKit
class MEFilter {
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var bufferSrcContext: UnsafeMutablePointer<AVFilterContext>?
    private var bufferSinkContext: UnsafeMutablePointer<AVFilterContext>?
    private var filters: String?
    private var configured = false
    private let options: KSOptions
    let timebase: Timebase
    private let isAudio: Bool
    private var params = AVBufferSrcParameters()
    private let nominalFrameRate: Float
    deinit {
        resetGraph()
        releaseParameters()
    }

    /// Codec seeks/restarts must also discard delayed filter frames (idet,
    /// deinterlacing and audio filters can retain input from the old timeline).
    func flush() {
        resetGraph()
        releaseParameters()
        filters = nil
    }

    private func resetGraph() {
        configured = false
        bufferSrcContext = nil; bufferSinkContext = nil
        graph?.pointee.opaque = nil
        avfilter_graph_free(&graph)
    }

    private func releaseParameters() {
        av_buffer_unref(&params.hw_frames_ctx)
        av_channel_layout_uninit(&params.ch_layout)
        params = AVBufferSrcParameters()
    }

    private func matches(_ next: AVBufferSrcParameters) -> Bool {
        params == next
            && params.time_base.num == next.time_base.num && params.time_base.den == next.time_base.den
            && params.frame_rate.num == next.frame_rate.num && params.frame_rate.den == next.frame_rate.den
            && params.sample_aspect_ratio.num == next.sample_aspect_ratio.num
            && params.sample_aspect_ratio.den == next.sample_aspect_ratio.den
            && params.hw_frames_ctx?.pointee.data == next.hw_frames_ctx?.pointee.data
            && params.color_space == next.color_space && params.color_range == next.color_range
            && params.alpha_mode == next.alpha_mode
    }

    public init(timebase: Timebase, isAudio: Bool, nominalFrameRate: Float, options: KSOptions) {
        self.options = options
        self.timebase = timebase
        self.isAudio = isAudio
        self.nominalFrameRate = nominalFrameRate
    }

    private func setup(filters: String) -> Bool {
        graph = avfilter_graph_alloc()
        guard let graph else { return false }
        graph.pointee.opaque = Unmanaged.passUnretained(options).toOpaque()
        // parse2 allocates its endpoint lists. Always release those lists on
        // success and every partial failure; the graph owns the filter contexts.
        var inputs: UnsafeMutablePointer<AVFilterInOut>?
        var outputs: UnsafeMutablePointer<AVFilterInOut>?
        defer { avfilter_inout_free(&inputs); avfilter_inout_free(&outputs) }
        var ret = avfilter_graph_parse2(graph, filters, &inputs, &outputs)
        guard ret >= 0, let inputs, let outputs,
              let bufferSink = avfilter_get_by_name(isAudio ? "abuffersink" : "buffersink"),
              let buffer = avfilter_get_by_name(isAudio ? "abuffer" : "buffer") else { return false }
        ret = avfilter_graph_create_filter(&bufferSinkContext, bufferSink, "out", nil, nil, graph)
        guard ret >= 0, bufferSinkContext != nil else { return false }
        ret = avfilter_link(outputs.pointee.filter_ctx, UInt32(outputs.pointee.pad_idx), bufferSinkContext, 0)
        guard ret >= 0 else { return false }
        bufferSrcContext = avfilter_graph_alloc_filter(graph, buffer, "in")
        guard let bufferSrcContext else { return false }
        ret = av_buffersrc_parameters_set(bufferSrcContext, &params)
        guard ret >= 0 else { return false }
        ret = avfilter_init_str(bufferSrcContext, nil)
        guard ret >= 0 else { return false }
        ret = avfilter_link(bufferSrcContext, 0, inputs.pointee.filter_ctx, UInt32(inputs.pointee.pad_idx))
        guard ret >= 0 else { return false }
        if let data = params.hw_frames_ctx?.pointee.data {
            let frames = UnsafeMutableRawPointer(data).assumingMemoryBound(to: AVHWFramesContext.self)
            if let device = frames.pointee.device_ref {
                // AVFilterContext owns this field and releases its reference.
                guard let reference = av_buffer_ref(device) else { return false }
                inputs.pointee.filter_ctx.pointee.hw_device_ctx = reference
            }
        }
        return avfilter_graph_config(graph, nil) >= 0
    }

    public func filter(options: KSOptions, inputFrame: UnsafeMutablePointer<AVFrame>, completionHandler: (UnsafeMutablePointer<AVFrame>) -> Void) {
        let filters: String
        if isAudio {
            filters = options.audioFilters.joined(separator: ",")
        } else {
            if options.autoDeInterlace, !options.videoFilters.contains("idet") {
                options.videoFilters.append("idet")
            }
            filters = options.videoFilters.joined(separator: ",")
        }
        guard !filters.isEmpty else {
            resetGraph(); releaseParameters(); self.filters = nil
            completionHandler(inputFrame)
            return
        }
        var params = AVBufferSrcParameters()
        params.format = inputFrame.pointee.format
        params.time_base = timebase.rational
        params.width = inputFrame.pointee.width
        params.height = inputFrame.pointee.height
        params.sample_aspect_ratio = inputFrame.pointee.sample_aspect_ratio
        if nominalFrameRate.isFinite, nominalFrameRate > 0 {
            params.frame_rate = av_d2q(Double(nominalFrameRate), 1_000_000)
        }
        // Borrow for comparison; retain only when this configuration changes.
        params.hw_frames_ctx = inputFrame.pointee.hw_frames_ctx
        params.color_space = inputFrame.pointee.colorspace
        params.color_range = inputFrame.pointee.color_range
        params.alpha_mode = inputFrame.pointee.alpha_mode
        params.sample_rate = inputFrame.pointee.sample_rate
        params.ch_layout = inputFrame.pointee.ch_layout
        if !matches(params) || self.filters != filters {
            resetGraph(); releaseParameters()
            self.params = params
            self.params.hw_frames_ctx = nil
            if let hardware = params.hw_frames_ctx { self.params.hw_frames_ctx = av_buffer_ref(hardware) }
            self.params.ch_layout = AVChannelLayout()
            let copied = av_channel_layout_copy(&self.params.ch_layout, &params.ch_layout)
            self.filters = filters
            configured = copied >= 0 && (params.hw_frames_ctx == nil || self.params.hw_frames_ctx != nil)
                && setup(filters: filters)
            if !configured {
                resetGraph()
                KSLog(level: .error, "Filter graph unavailable; passing decoded frames without filters: \(filters)")
            }
        }
        // An unsuccessful configuration remains a bypass for every matching
        // frame. Cached parameters never imply that source/sink creation worked.
        guard configured, let bufferSrcContext, let bufferSinkContext else {
            completionHandler(inputFrame)
            return
        }
        // Keep our input until the complete push succeeds. Native filters can
        // fail after taking a frame reference into their internal queue.
        let ret = av_buffersrc_add_frame_flags(bufferSrcContext, inputFrame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF))
        if ret < 0 {
            resetGraph()
            KSLog(level: .error, "Filter source failed (\(ret)); passing decoded frames without filters: \(filters)")
            completionHandler(inputFrame)
            return
        }
        av_frame_unref(inputFrame)
        while true {
            let result = av_buffersink_get_frame_flags(bufferSinkContext, inputFrame, 0)
            guard result >= 0 else {
                if result != AVError.tryAgain.code, result != AVError.eof.code {
                    resetGraph()
                    KSLog(level: .error, "Filter sink failed (\(result)); passing subsequent decoded frames without filters: \(filters)")
                }
                break
            }
            completionHandler(inputFrame)
            // 一定要加av_frame_unref，不然会内存泄漏。
            av_frame_unref(inputFrame)
        }
    }
}
