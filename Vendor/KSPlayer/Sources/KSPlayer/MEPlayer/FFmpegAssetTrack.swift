//
//  FFmpegAssetTrack.swift
//  KSPlayer
//
//  Created by kintan on 2023/2/12.
//

import AVFoundation
import FFmpegKit
public class FFmpegAssetTrack: MediaPlayerTrack {
    public private(set) var trackID: Int32 = 0
    public let codecName: String
    public var name: String = ""
    public private(set) var languageCode: String?
    public var nominalFrameRate: Float = 0
    public private(set) var avgFrameRate = Timebase.defaultValue
    public private(set) var realFrameRate = Timebase.defaultValue
    public private(set) var bitRate: Int64 = 0
    public let mediaType: AVFoundation.AVMediaType
    public let formatName: String?
    public let bitDepth: Int32
    private var stream: UnsafeMutablePointer<AVStream>?
    var startTime = CMTime.zero
    var codecpar: AVCodecParameters
    var timebase: Timebase = .defaultValue
    let bitsPerRawSample: Int32
    // audio
    public let audioDescriptor: AudioDescriptor?
    // subtitle
    public let isImageSubtitle: Bool
    public var delay: TimeInterval = 0
    var subtitle: SyncPlayerItemTrack<SubtitleFrame>?
    // video
    public private(set) var rotation: Int16 = 0
    public var dovi: DOVIDecoderConfigurationRecord?
    /// Separate UHD residual layers are not independent video choices.
    public internal(set) var isDolbyVisionEnhancementLayer = false
    public internal(set) var hasDolbyVisionEnhancementLayer = false
    public internal(set) var convertsDolbyVisionP7ToP81 = false
    var requiresNativeDolbyVision: Bool { dovi?.dv_profile == 5 || convertsDolbyVisionP7ToP81 }
    public let fieldOrder: FFmpegFieldOrder
    public let formatDescription: CMFormatDescription?
    var closedCaptionsTrack: FFmpegAssetTrack?
    let isConvertNALSize: Bool
    private(set) var isAnnexB = false
    private(set) var nalLengthFieldBytes = 4
    var seekByBytes = false
    public var description: String {
        var description = codecName
        if let formatName {
            description += ", \(formatName)"
        }
        if bitsPerRawSample > 0 {
            description += "(\(bitsPerRawSample.kmFormatted) bit)"
        }
        if let audioDescriptor {
            description += ", \(audioDescriptor.sampleRate)Hz"
            description += ", \(audioDescriptor.channel.description)"
        }
        if let formatDescription {
            if mediaType == .video {
                let naturalSize = formatDescription.naturalSize
                description += ", \(Int(naturalSize.width))x\(Int(naturalSize.height))"
                description += String(format: ", %.2f fps", nominalFrameRate)
            }
        }
        if bitRate > 0 {
            description += ", \(bitRate.kmFormatted)bps"
        }
        if let language {
            description += "(\(language))"
        }
        return description
    }

    convenience init?(stream: UnsafeMutablePointer<AVStream>) {
        // `codecpar` is imported as an implicitly unwrapped optional, but
        // FFmpeg leaves it NULL for streams it has no parser for (e.g. the
        // `bin_data` streams present in many DVB/MPEG-TS muxes). This
        // initialiser is already failable, so skip the stream rather than
        // trapping — createCodec's compactMap drops it.
        guard let codecpar = stream.pointee.codecpar?.pointee else { return nil }
        self.init(codecpar: codecpar)
        self.stream = stream
        let metadata = toDictionary(stream.pointee.metadata)
        if let value = metadata["variant_bitrate"] ?? metadata["BPS"], let bitRate = Int64(value) {
            self.bitRate = bitRate
        }
        trackID = stream.pointee.index
        var timebase = Timebase(stream.pointee.time_base)
        if timebase.num <= 0 || timebase.den <= 0 {
            timebase = Timebase(num: 1, den: 1000)
        }
        if stream.pointee.start_time != Int64.min {
            startTime = timebase.cmtime(for: stream.pointee.start_time)
        }
        self.timebase = timebase
        avgFrameRate = Timebase(stream.pointee.avg_frame_rate)
        realFrameRate = Timebase(stream.pointee.r_frame_rate)
        if mediaType == .audio {
            nominalFrameRate = Self.audioNominalFrameRate(
                sampleRate: codecpar.sample_rate,
                frameSize: codecpar.frame_size,
                codecID: codecpar.codec_id
            )
        } else {
            if stream.pointee.duration > 0, stream.pointee.nb_frames > 0, stream.pointee.nb_frames != stream.pointee.duration {
                nominalFrameRate = Float(stream.pointee.nb_frames) * Float(timebase.den) / Float(stream.pointee.duration) * Float(timebase.num)
            } else if avgFrameRate.den > 0, avgFrameRate.num > 0 {
                nominalFrameRate = Float(avgFrameRate.num) / Float(avgFrameRate.den)
            } else {
                nominalFrameRate = 24
            }
        }

        if let value = metadata["language"], value != "und" {
            languageCode = value
        } else {
            languageCode = nil
        }
        if let value = metadata["title"] {
            name = value
        } else {
            name = languageCode ?? codecName
        }
        // AV_DISPOSITION_DEFAULT
        if mediaType == .subtitle {
            isEnabled = !isImageSubtitle || stream.pointee.disposition & AV_DISPOSITION_FORCED == AV_DISPOSITION_FORCED
            if stream.pointee.disposition & AV_DISPOSITION_HEARING_IMPAIRED == AV_DISPOSITION_HEARING_IMPAIRED {
                name += "(hearing impaired)"
            }
        }
        //        var buf = [Int8](repeating: 0, count: 256)
        //        avcodec_string(&buf, buf.count, codecpar, 0)
    }

    /// Audio `nominalFrameRate` derived from `sample_rate` / `frame_size`.
    ///
    /// `AVCodecParameters.frame_size` is audio-only and left at `0` by most
    /// demuxers (AAC/MP3/Opus/FLAC/Vorbis) until the first frame is decoded,
    /// and a `0` divisor traps Swift with a divide-by-zero. When it is unset,
    /// fall back to codec-aware constants
    /// instead of deriving a frame size arithmetically. `sample_rate` can also
    /// be `0` pre-decode, so guard both before dividing — mirroring
    /// `AudioDescriptor`'s own `sampleRate <= 0` guard (`Resample.swift`).
    static func audioNominalFrameRate(sampleRate: Int32, frameSize: Int32, codecID: AVCodecID) -> Float {
        // Suggested by the maintainer: codec-aware fallbacks instead of deriving a
        // frame size from the stream timebase (whose den/num can integer-divide to 0).
        let fallback: Int32
        switch codecID {
        case AV_CODEC_ID_TRUEHD: fallback = 48
        case AV_CODEC_ID_AAC, AV_CODEC_ID_AAC_LATM, AV_CODEC_ID_AV3A: fallback = 1024
        case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: fallback = 1536
        case AV_CODEC_ID_MP2, AV_CODEC_ID_MP3: fallback = 1152
        case AV_CODEC_ID_OPUS: fallback = 960
        default: fallback = 1000
        }
        let effectiveFrameSize = frameSize > 0 ? frameSize : fallback
        guard sampleRate > 0, effectiveFrameSize > 0 else {
            return 48
        }
        // Preserve fractional rates. EAC3 at 48 kHz is 31.25 packets/s;
        // clamping it to 48 makes a 45-second queue retain 69 seconds.
        return Float(sampleRate) / Float(effectiveFrameSize)
    }

    init?(codecpar: AVCodecParameters) {
        self.codecpar = codecpar
        bitRate = codecpar.bit_rate
        // codec_tag byte order is LSB first CMFormatDescription.MediaSubType(rawValue: codecpar.codec_tag.bigEndian)
        let codecType = codecpar.codec_id.mediaSubType
        var codecName = ""
        if let descriptor = avcodec_descriptor_get(codecpar.codec_id) {
            codecName += String(cString: descriptor.pointee.name)
            if let profile = descriptor.pointee.profiles {
                codecName += " (\(String(cString: profile.pointee.name)))"
            }
        } else {
            codecName = ""
        }
        self.codecName = codecName
        fieldOrder = FFmpegFieldOrder(rawValue: UInt8(codecpar.field_order.rawValue)) ?? .unknown
        var formatDescriptionOut: CMFormatDescription?
        if codecpar.codec_type == AVMEDIA_TYPE_AUDIO {
            mediaType = .audio
            audioDescriptor = AudioDescriptor(codecpar: codecpar)
            isConvertNALSize = false
            bitDepth = 0
            let layout = codecpar.ch_layout
            let channelsPerFrame = UInt32(layout.nb_channels)
            let sampleFormat = AVSampleFormat(codecpar.format)
            let bytesPerSample = UInt32(av_get_bytes_per_sample(sampleFormat))
            let formatFlags = ((sampleFormat == AV_SAMPLE_FMT_FLT || sampleFormat == AV_SAMPLE_FMT_DBL) ? kAudioFormatFlagIsFloat : sampleFormat == AV_SAMPLE_FMT_U8 ? 0 : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
            var audioStreamBasicDescription = AudioStreamBasicDescription(mSampleRate: Float64(codecpar.sample_rate), mFormatID: codecType.rawValue, mFormatFlags: formatFlags, mBytesPerPacket: bytesPerSample * channelsPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerSample * channelsPerFrame, mChannelsPerFrame: channelsPerFrame, mBitsPerChannel: bytesPerSample * 8, mReserved: 0)
            _ = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &audioStreamBasicDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescriptionOut)
            if let name = av_get_sample_fmt_name(sampleFormat) {
                formatName = String(cString: name)
            } else {
                formatName = nil
            }
        } else if codecpar.codec_type == AVMEDIA_TYPE_VIDEO {
            audioDescriptor = nil
            mediaType = .video
            if codecpar.nb_coded_side_data > 0, let sideDatas = codecpar.coded_side_data {
                for i in 0 ..< codecpar.nb_coded_side_data {
                    let sideData = sideDatas[Int(i)]
                    if sideData.type == AV_PKT_DATA_DOVI_CONF, sideData.size >= 8, let data = sideData.data {
                        // FFmpeg's record size is not ABI-stable; copy documented
                        // bytes and tolerate the pre-compression eight-byte form.
                        dovi = DOVIDecoderConfigurationRecord(dv_version_major: data[0], dv_version_minor: data[1],
                            dv_profile: data[2], dv_level: data[3], rpu_present_flag: data[4], el_present_flag: data[5],
                            bl_present_flag: data[6], dv_bl_signal_compatibility_id: data[7], dv_md_compression: sideData.size > 8 ? data[8] : 0)
                    } else if sideData.type == AV_PKT_DATA_DISPLAYMATRIX {
                        let matrix = sideData.data.withMemoryRebound(to: Int32.self, capacity: 1) { $0 }
                        let rawRotation = -av_display_rotation_get(matrix)
                        if rawRotation.isFinite {
                            let degrees = Int(rawRotation.rounded())
                            let normalized = ((degrees % 360) + 360) % 360
                            rotation = Int16(normalized)
                        } else {
                            rotation = 0
                        }                        
                    }
                }
            }
            let sar = codecpar.sample_aspect_ratio.size
            var extradataSize = Int32(0)
            var extradata = codecpar.extradata
            let atomsData: Data?
            if codecpar.codec_id == AV_CODEC_ID_AV1 {
                atomsData = Self.av1ConfigurationRecord(codecpar)
                isConvertNALSize = false
            } else if let extradata {
                extradataSize = codecpar.extradata_size
                var data = Data(bytes: extradata, count: max(0, Int(extradataSize)))
                let isNALCodec = [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].contains(codecType.rawValue)
                isAnnexB = isNALCodec && VideoNALFormat.isAnnexB(data)
                if !isAnnexB, isNALCodec, data.first == 1 {
                    // AVC's lengthSizeMinusOne is byte 4; HEVC's is byte 21.
                    // Rewrite an owned atom, never FFmpeg's shared extradata.
                    let field = codecType.rawValue == kCMVideoCodecType_HEVC ? 21 : 4
                    if data.count > field {
                        nalLengthFieldBytes = Int(data[field] & 3) + 1
                        data[field] = (data[field] & 0xfc) | 3
                    }
                }
                isConvertNALSize = !isAnnexB && isNALCodec && nalLengthFieldBytes != 4
                atomsData = data
            } else {
                if codecType.rawValue == kCMVideoCodecType_VP9 {
                    // ff_videotoolbox_vpcc_extradata_create
                    var ioContext: UnsafeMutablePointer<AVIOContext>?
                    guard avio_open_dyn_buf(&ioContext) == 0 else {
                        return nil
                    }
                    ff_isom_write_vpcc(nil, ioContext, nil, 0, &self.codecpar)
                    extradataSize = avio_close_dyn_buf(ioContext, &extradata)
                    guard let extradata else {
                        return nil
                    }
                    var data = Data()
                    var array: [UInt8] = [1, 0, 0, 0]
                    data.append(&array, count: 4)
                    data.append(extradata, count: Int(extradataSize))
                    atomsData = data
                } else {
                    atomsData = nil
                }
                isConvertNALSize = false
            }
            let format = AVPixelFormat(rawValue: codecpar.format)
            bitDepth = format.bitDepth
            let fullRange = codecpar.color_range == AVCOL_RANGE_JPEG
            let dic: NSMutableDictionary = [
                kCVImageBufferChromaLocationBottomFieldKey: kCVImageBufferChromaLocation_Left,
                kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Left,
                kCMFormatDescriptionExtension_Depth: format.bitDepth * Int32(format.planeCount),
                kCMFormatDescriptionExtension_FullRangeVideo: fullRange,
                codecType.rawValue == kCMVideoCodecType_HEVC ? "EnableHardwareAcceleratedVideoDecoder" : "RequireHardwareAcceleratedVideoDecoder": true,
            ]
            if codecpar.nb_coded_side_data > 0, let sideData = codecpar.coded_side_data {
                for index in 0 ..< Int(codecpar.nb_coded_side_data) {
                    let side = sideData[index]
                    guard let bytes = side.data else { continue }
                    if side.type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
                       side.size >= MemoryLayout<AVMasteringDisplayMetadata>.size,
                       let metadata = VideoColorMetadata.masteringData(UnsafeRawPointer(bytes).load(as: AVMasteringDisplayMetadata.self)) {
                        dic[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = metadata
                    } else if side.type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL,
                              side.size >= MemoryLayout<AVContentLightMetadata>.size {
                        dic[kCMFormatDescriptionExtension_ContentLightLevelInfo] = VideoColorMetadata.contentLightData(
                            UnsafeRawPointer(bytes).load(as: AVContentLightMetadata.self))
                    }
                }
            }
            // kCMFormatDescriptionExtension_BitsPerComponent
            if let atomsData {
                var nativeAtom = atomsData
                if isAnnexB, let parsed = VideoNALFormat.makeFormatDescription(parameterSets: atomsData,
                    codec: codecType.rawValue, extensions: dic),
                   let extensions = CMFormatDescriptionGetExtension(parsed,
                    extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data],
                   let atom = extensions[codecType.rawValue.avc] {
                    nativeAtom = atom
                }
                var atoms = [codecType.rawValue.avc: nativeAtom]
                if let dovi, codecType.rawValue == kCMVideoCodecType_HEVC, [5, 8].contains(dovi.dv_profile) {
                    atoms[dovi.dv_profile > 7 ? "dvvC" : "dvcC"] = dovi.configurationData
                }
                dic[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms
            }
            dic[kCVPixelBufferPixelFormatTypeKey] = format.osType(fullRange: fullRange)
            dic[kCVImageBufferPixelAspectRatioKey] = sar.aspectRatio
            dic[kCVImageBufferColorPrimariesKey] = codecpar.color_primaries.colorPrimaries as String?
            dic[kCVImageBufferTransferFunctionKey] = codecpar.color_trc.transferFunction as String?
            dic[kCVImageBufferYCbCrMatrixKey] = codecpar.color_space.ycbcrMatrix as String?
            // swiftlint:disable line_length
            let nativeCodec = codecType.rawValue == kCMVideoCodecType_HEVC && dovi?.dv_profile == 5 ? kCMVideoCodecType_DolbyVisionHEVC : codecType.rawValue
            _ = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: nativeCodec, width: codecpar.width, height: codecpar.height, extensions: dic, formatDescriptionOut: &formatDescriptionOut)
            // swiftlint:enable line_length
            if let name = av_get_pix_fmt_name(format) {
                formatName = String(cString: name)
            } else {
                formatName = nil
            }
        } else if codecpar.codec_type == AVMEDIA_TYPE_SUBTITLE {
            mediaType = .subtitle
            audioDescriptor = nil
            formatName = nil
            bitDepth = 0
            isConvertNALSize = false
            _ = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Subtitle, mediaSubType: codecType.rawValue, extensions: nil, formatDescriptionOut: &formatDescriptionOut)
        } else {
            bitDepth = 0
            return nil
        }
        formatDescription = formatDescriptionOut
        bitsPerRawSample = codecpar.bits_per_raw_sample
        isImageSubtitle = [AV_CODEC_ID_DVD_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE, AV_CODEC_ID_DVB_TELETEXT, AV_CODEC_ID_HDMV_PGS_SUBTITLE].contains(codecpar.codec_id)
        trackID = 0
    }

    private static func av1ConfigurationRecord(_ codecpar: AVCodecParameters) -> Data? {
        guard let bytes = codecpar.extradata, codecpar.extradata_size > 0 else { return nil }
        var context: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&context) >= 0, let context else { return nil }
        // FFmpeg accepts both av1C and raw OBUs. Keep the sequence header in the
        // generated record and parse from FFmpeg's padded extradata allocation.
        let status = ff_isom_write_av1c(context, bytes, codecpar.extradata_size, 1)
        avio_flush(context)
        let ioError = context.pointee.error
        var output: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(context, &output)
        defer { av_free(output) }
        guard status >= 0, ioError >= 0, size >= 4, let output else { return nil }
        return Data(bytes: output, count: Int(size))
    }

    func createContext(options: KSOptions, hardwareDecode: Bool? = nil) throws -> UnsafeMutablePointer<AVCodecContext> {
        try codecpar.createContext(options: options, hardwareDecode: hardwareDecode)
    }

    public var isEnabled: Bool {
        get {
            if isDolbyVisionEnhancementLayer { return false }
            return stream?.pointee.discard == AVDISCARD_DEFAULT
        }
        set {
            if isDolbyVisionEnhancementLayer {
                // Retain RPU demuxing while never selecting residual pixels.
                stream?.pointee.discard = AVDISCARD_DEFAULT
                return
            }
            var discard = newValue ? AVDISCARD_DEFAULT : AVDISCARD_ALL
            if mediaType == .subtitle, !isImageSubtitle {
                discard = AVDISCARD_DEFAULT
            }
            stream?.pointee.discard = discard
        }
    }
}

extension FFmpegAssetTrack {
    var pixelFormatType: OSType? {
        let format = AVPixelFormat(codecpar.format)
        if codecpar.codec_id == AV_CODEC_ID_AV1, format == AV_PIX_FMT_YUV420P {
            return AV_PIX_FMT_NV12.osType(fullRange: codecpar.color_range == AVCOL_RANGE_JPEG)
        }
        return format.osType(fullRange: formatDescription?.fullRangeVideo ?? false)
    }
}
