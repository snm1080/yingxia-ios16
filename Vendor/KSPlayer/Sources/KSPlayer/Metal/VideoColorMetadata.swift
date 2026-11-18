import AVFoundation
import FFmpegKit
import Foundation

enum VideoColorMetadata {
    static func isFullRange(pixelFormat: OSType, attachment: Bool?) -> Bool {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8PlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8Planar,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            return false
        default:
            return attachment ?? false
        }
    }

    static func apply(frame: UnsafePointer<AVFrame>, pixelBuffer: CVPixelBuffer) {
        // FFmpeg's public mapper includes chroma, SAR, transfer, primaries,
        // matrix and gamma and removes stale values when a pool is reused.
        _ = av_vt_pixbuf_set_attachments(nil, pixelBuffer, frame)
        applyHDR(frame: frame, pixelBuffer: pixelBuffer)
    }

    /// VT can convert Dolby/HDR to another output range. Its actual output
    /// labels take precedence; input labels only repair missing attachments.
    static func applyMissing(pixelBuffer: CVPixelBuffer, primaries: CFString?, transfer: CFString?, matrix: CFString?) {
        for (key, value) in [(kCVImageBufferColorPrimariesKey, primaries),
                             (kCVImageBufferTransferFunctionKey, transfer),
                             (kCVImageBufferYCbCrMatrixKey, matrix)] {
            if CVBufferGetAttachment(pixelBuffer, key, nil) == nil, let value {
                CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
            }
        }
    }

    static func masteringData(_ metadata: AVMasteringDisplayMetadata) -> Data? {
        guard metadata.has_primaries != 0, metadata.has_luminance != 0 else { return nil }
        let chromaticities = [metadata.display_primaries.1.0, metadata.display_primaries.1.1,
                              metadata.display_primaries.2.0, metadata.display_primaries.2.1,
                              metadata.display_primaries.0.0, metadata.display_primaries.0.1,
                              metadata.white_point.0, metadata.white_point.1]
        var data = Data()
        for coordinate in chromaticities {
            guard let encoded = scaled(coordinate, scale: 50_000, maximum: UInt64(UInt16.max)) else { return nil }
            append(UInt16(encoded), to: &data)
        }
        // ISO 23008-2 D.2.28 stores max followed by min, in 0.0001 cd/m2.
        for luminance in [metadata.max_luminance, metadata.min_luminance] {
            guard let encoded = scaled(luminance, scale: 10_000, maximum: UInt64(UInt32.max)) else { return nil }
            append(UInt32(encoded), to: &data)
        }
        return data
    }

    static func contentLightData(_ metadata: AVContentLightMetadata) -> Data {
        var data = Data()
        append(UInt16(clamping: metadata.MaxCLL), to: &data)
        append(UInt16(clamping: metadata.MaxFALL), to: &data)
        return data
    }

    static func applyHDR(frame: UnsafePointer<AVFrame>, pixelBuffer: CVPixelBuffer) {
        let value = frame.pointee
        let hdr = value.color_trc == AVCOL_TRC_SMPTE2084 || value.color_trc == AVCOL_TRC_ARIB_STD_B67
        var mastering: Data?
        var light: Data?
        if hdr, value.nb_side_data > 0, let sideData = value.side_data {
            for index in 0 ..< Int(value.nb_side_data) {
                guard let side = sideData[index], let bytes = side.pointee.data else { continue }
                if side.pointee.type == AV_FRAME_DATA_MASTERING_DISPLAY_METADATA,
                   side.pointee.size >= MemoryLayout<AVMasteringDisplayMetadata>.size {
                    mastering = masteringData(UnsafeRawPointer(bytes).load(as: AVMasteringDisplayMetadata.self))
                } else if side.pointee.type == AV_FRAME_DATA_CONTENT_LIGHT_LEVEL,
                          side.pointee.size >= MemoryLayout<AVContentLightMetadata>.size {
                    light = contentLightData(UnsafeRawPointer(bytes).load(as: AVContentLightMetadata.self))
                }
            }
        }
        set(mastering, key: kCVImageBufferMasteringDisplayColorVolumeKey, pixelBuffer: pixelBuffer)
        set(light, key: kCVImageBufferContentLightLevelInfoKey, pixelBuffer: pixelBuffer)
    }

    private static func set(_ value: Data?, key: CFString, pixelBuffer: CVPixelBuffer) {
        if let value { CVBufferSetAttachment(pixelBuffer, key, value as CFData, .shouldPropagate) }
        else { CVBufferRemoveAttachment(pixelBuffer, key) }
    }

    private static func scaled(_ value: AVRational, scale: Double, maximum: UInt64) -> UInt64? {
        guard value.den > 0, value.num >= 0 else { return nil }
        let number = Double(value.num) / Double(value.den) * scale
        guard number.isFinite, number <= Double(maximum) else { return nil }
        return UInt64(number.rounded())
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}
