//
//  VideoToolboxDecode.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/10.
//

import FFmpegKit
#if canImport(VideoToolbox)
import VideoToolbox

class VideoToolboxDecode: DecodeProtocol {
    private var session: DecompressionSession {
        didSet {
            VTDecompressionSessionInvalidate(oldValue.decompressionSession)
        }
    }

    private let options: KSOptions
    private var startTime = Int64(0)
    private var lastPosition = Int64(0)
    private var needReconfig = false

    init(options: KSOptions, session: DecompressionSession) {
        self.options = options
        self.session = session
    }

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        if needReconfig {
            // 解决从后台切换到前台，解码失败的问题
            guard let replacement = DecompressionSession(assetTrack: session.assetTrack, options: options,
                formatDescription: session.formatDescription) else {
                completionHandler(.failure(NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: kVTInvalidSessionErr)))
                return
            }
            session = replacement
            doFlushCodec()
            needReconfig = false
        }
        guard let corePacket = packet.corePacket?.pointee, let data = corePacket.data else {
            return
        }
        do {
            if packet.isKeyFrame, session.assetTrack.isAnnexB, corePacket.size > 0,
               let updated = VideoNALFormat.updatedFormatDescription(sample: Data(bytes: data, count: Int(corePacket.size)),
                    current: session.formatDescription) {
                // Drain old callbacks before invalidating their native session.
                // They keep their own format/timing metadata; the current packet
                // must be decoded exactly once with the new SPS/PPS.
                VTDecompressionSessionWaitForAsynchronousFrames(session.decompressionSession)
                guard let replacement = DecompressionSession(assetTrack: session.assetTrack, options: options,
                    formatDescription: updated) else {
                    throw NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: kVTVideoDecoderUnsupportedDataFormatErr)
                }
                session = replacement
            }
            let decodingSession = session
            let sampleBuffer = try decodingSession.formatDescription.getSampleBuffer(annexB: decodingSession.assetTrack.isAnnexB,
                lengthFieldBytes: decodingSession.assetTrack.nalLengthFieldBytes,
                isConvertNALSize: decodingSession.assetTrack.isConvertNALSize, data: data, size: Int(corePacket.size))
            let flags: VTDecodeFrameFlags = [
                ._EnableAsynchronousDecompression,
            ]
            var flagOut = VTDecodeInfoFlags.frameDropped
            let timestamp = packet.timestamp
            let packetFlags = corePacket.flags
            let duration = corePacket.duration
            let size = corePacket.size
            let status = VTDecompressionSessionDecodeFrame(decodingSession.decompressionSession, sampleBuffer: sampleBuffer, flags: flags, infoFlagsOut: &flagOut) { [weak self] status, infoFlags, imageBuffer, _, _ in
                guard let self else {
                    return
                }
                guard status == noErr else {
                    completionHandler(.failure(NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: status)))
                    return
                }
                guard !infoFlags.contains(.frameDropped), let imageBuffer else { return }
                decodingSession.applyOutputMetadata(to: imageBuffer)
                let frame = VideoVTBFrame(fps: decodingSession.assetTrack.nominalFrameRate, isDovi: decodingSession.assetTrack.dovi != nil)
                frame.corePixelBuffer = imageBuffer
                frame.timebase = decodingSession.assetTrack.timebase
                if packet.isKeyFrame, packetFlags & AV_PKT_FLAG_DISCARD != 0, self.lastPosition > 0 {
                    self.startTime = self.lastPosition - timestamp
                }
                self.lastPosition = max(self.lastPosition, timestamp)
                frame.position = packet.position
                frame.timestamp = self.startTime + timestamp
                frame.duration = duration
                frame.size = size
                self.lastPosition += frame.duration
                completionHandler(.success(frame))
            }
            if status == noErr {
                if !flags.contains(._EnableAsynchronousDecompression) {
                    VTDecompressionSessionWaitForAsynchronousFrames(session.decompressionSession)
                }
            } else if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
                if packet.isKeyFrame {
                    throw NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: status)
                } else {
                    // 解决从后台切换到前台，解码失败的问题
                    needReconfig = true
                }
            } else {
                throw NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: status)
            }
        } catch {
            completionHandler(.failure(error))
        }
    }

    func doFlushCodec() {
        // The decode worker calls flush after the track has invalidated its
        // output generation. Drain native callbacks before resetting their
        // timestamp basis; they must not modify the next seek's state later.
        VTDecompressionSessionWaitForAsynchronousFrames(session.decompressionSession)
        lastPosition = 0
        startTime = 0
    }

    func shutdown() {
        VTDecompressionSessionInvalidate(session.decompressionSession)
    }

    func decode() {
        lastPosition = 0
        startTime = 0
    }
}

class DecompressionSession {
    fileprivate let formatDescription: CMFormatDescription
    fileprivate let decompressionSession: VTDecompressionSession
    fileprivate var assetTrack: FFmpegAssetTrack
    private let preserveInputColor: Bool
    init?(assetTrack: FFmpegAssetTrack, options: KSOptions, formatDescription replacement: CMFormatDescription? = nil) {
        self.assetTrack = assetTrack
        guard let pixelFormatType = assetTrack.pixelFormatType, let formatDescription = replacement ?? assetTrack.formatDescription else {
            return nil
        }
        self.formatDescription = formatDescription
        #if os(macOS)
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
        if #available(macOS 11.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(formatDescription.mediaSubType.rawValue)
        }
        #endif
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let attributes: NSMutableDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormatType,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferWidthKey: dimensions.width,
            kCVPixelBufferHeightKey: dimensions.height,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        var session: VTDecompressionSession?
        // swiftlint:disable line_length
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: formatDescription, decoderSpecification: CMFormatDescriptionGetExtensions(formatDescription), imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
        // swiftlint:enable line_length
        guard status == noErr, let decompressionSession = session else {
            return nil
        }
        if #available(iOS 14.0, tvOS 14.0, macOS 11.0, *) {
            VTSessionSetProperty(decompressionSession, key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
                                 value: kCFBooleanTrue)
        }
        if let destinationDynamicRange = options.availableDynamicRange(nil) {
            let pixelTransferProperties = [kVTPixelTransferPropertyKey_DestinationColorPrimaries: destinationDynamicRange.colorPrimaries,
                                           kVTPixelTransferPropertyKey_DestinationTransferFunction: destinationDynamicRange.transferFunction,
                                           kVTPixelTransferPropertyKey_DestinationYCbCrMatrix: destinationDynamicRange.yCbCrMatrix]
            VTSessionSetProperty(decompressionSession,
                                 key: kVTDecompressionPropertyKey_PixelTransferProperties,
                                 value: pixelTransferProperties as CFDictionary)
            preserveInputColor = false
        } else {
            preserveInputColor = assetTrack.dovi?.dv_profile != 5
        }
        self.decompressionSession = decompressionSession
    }

    fileprivate func applyOutputMetadata(to pixelBuffer: CVPixelBuffer) {
        // P5 is converted by the Dolby native decoder. Never tag unconverted
        // IPT samples as ordinary BT2020 YUV by copying container labels.
        guard preserveInputColor else { return }
        func currentColor(_ key: CFString) -> CFString? {
            (CMFormatDescriptionGetExtension(formatDescription, extensionKey: key) as? String).map { $0 as CFString }
        }
        VideoColorMetadata.applyMissing(pixelBuffer: pixelBuffer,
            primaries: currentColor(kCMFormatDescriptionExtension_ColorPrimaries) ?? assetTrack.codecpar.color_primaries.colorPrimaries,
            transfer: currentColor(kCMFormatDescriptionExtension_TransferFunction) ?? assetTrack.codecpar.color_trc.transferFunction,
            matrix: currentColor(kCMFormatDescriptionExtension_YCbCrMatrix) ?? assetTrack.codecpar.color_space.ycbcrMatrix)
        let description = formatDescription
        for (formatKey, bufferKey) in [
            (kCMFormatDescriptionExtension_MasteringDisplayColorVolume, kCVImageBufferMasteringDisplayColorVolumeKey),
            (kCMFormatDescriptionExtension_ContentLightLevelInfo, kCVImageBufferContentLightLevelInfoKey),
        ] {
            if CVBufferGetAttachment(pixelBuffer, bufferKey, nil) == nil,
               let value = CMFormatDescriptionGetExtension(description, extensionKey: formatKey) {
                CVBufferSetAttachment(pixelBuffer, bufferKey, value, .shouldPropagate)
            }
        }
    }
}
#endif

extension CMFormatDescription {
    fileprivate func getSampleBuffer(annexB: Bool, lengthFieldBytes: Int, isConvertNALSize: Bool,
                                    data: UnsafeMutablePointer<UInt8>, size: Int) throws -> CMSampleBuffer {
        guard size > 0 else { throw VideoNALFormat.InvalidSample.malformedNAL }
        if annexB || isConvertNALSize {
            let native = try VideoNALFormat.sampleData(Data(bytes: data, count: size), annexB: annexB,
                                                       lengthFieldBytes: lengthFieldBytes)
            return try native.withUnsafeBytes { bytes in
                try createSampleBuffer(data: bytes.baseAddress, size: bytes.count)
            }
        }
        return try createSampleBuffer(data: data, size: size)
    }

    private func createSampleBuffer(data: UnsafeRawPointer?, size: Int) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var sampleBuffer: CMSampleBuffer?
        // swiftlint:disable line_length
        // Asynchronous VT decode outlives this call and the demux packet. The
        // block buffer must own its compressed bytes, including converted NALs.
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &blockBuffer)
        if status == noErr, let blockBuffer, let data {
            status = CMBlockBufferReplaceDataBytes(with: data, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: size)
        }
        if status == noErr {
            status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: self, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
            if let sampleBuffer {
                return sampleBuffer
            }
        }
        throw NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: status)
        // swiftlint:enable line_length
    }
}

extension CMVideoCodecType {
    var avc: String {
        switch self {
        case kCMVideoCodecType_MPEG4Video:
            return "esds"
        case kCMVideoCodecType_H264:
            return "avcC"
        case kCMVideoCodecType_HEVC:
            return "hvcC"
        case kCMVideoCodecType_VP9:
            return "vpcC"
        default: return "avcC"
        }
    }
}
