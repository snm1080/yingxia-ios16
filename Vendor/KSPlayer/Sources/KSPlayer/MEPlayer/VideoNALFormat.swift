import CoreMedia
import Foundation

/// Bridges Annex B (MPEG-TS/Blu-ray) to Apple's native AVC/HEVC sample format.
enum VideoNALFormat {
    enum InvalidSample: Error { case malformedNAL }

    static func isAnnexB(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        return bytes.starts(with: [0, 0, 1]) || bytes.starts(with: [0, 0, 0, 1])
    }

    static func annexBUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, payload: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, index + 3)); index += 3; continue
                } else if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, index + 4)); index += 4; continue
                }
            }
            index += 1
        }
        return starts.enumerated().compactMap { offset, start in
            var end = offset + 1 < starts.count ? starts[offset + 1].offset : bytes.count
            // Annex B trailing_zero_8bits are outside the NAL unit.
            while end > start.payload, bytes[end - 1] == 0 { end -= 1 }
            return end > start.payload ? Data(bytes[start.payload ..< end]) : nil
        }
    }

    static func sampleData(_ data: Data, annexB: Bool, lengthFieldBytes: Int) throws -> Data {
        let units: [Data]
        if annexB {
            units = annexBUnits(data)
            guard !units.isEmpty else { throw InvalidSample.malformedNAL }
        } else {
            guard [1, 2, 3, 4].contains(lengthFieldBytes) else { throw InvalidSample.malformedNAL }
            let bytes = [UInt8](data)
            var parsed: [Data] = []
            var offset = 0
            while offset < bytes.count {
                guard offset + lengthFieldBytes <= bytes.count else { throw InvalidSample.malformedNAL }
                var length = 0
                for index in 0 ..< lengthFieldBytes { length = (length << 8) | Int(bytes[offset + index]) }
                offset += lengthFieldBytes
                guard length > 0, length <= bytes.count - offset else { throw InvalidSample.malformedNAL }
                parsed.append(Data(bytes[offset ..< offset + length]))
                offset += length
            }
            guard !parsed.isEmpty else { throw InvalidSample.malformedNAL }
            units = parsed
        }
        var result = Data()
        result.reserveCapacity(data.count + units.count)
        for unit in units {
            guard unit.count <= UInt32.max else { throw InvalidSample.malformedNAL }
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(unit)
        }
        return result
    }

    /// HLS discontinuities can switch from an advertisement's SPS/PPS to a
    /// different picture size/profile. Only complete, in-band parameter sets
    /// are authoritative; never combine half of a new format with the old one.
    static func updatedFormatDescription(sample: Data, current: CMFormatDescription) -> CMFormatDescription? {
        let codec = CMFormatDescriptionGetMediaSubType(current)
        guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC,
              let parsed = makeFormatDescription(parameterSets: sample, codec: codec, extensions: nil),
              let atoms = CMFormatDescriptionGetExtension(parsed,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data]
        else { return nil }
        let oldAtoms = CMFormatDescriptionGetExtension(current,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data] ?? [:]
        let size = CMVideoFormatDescriptionGetDimensions(parsed)
        let oldSize = CMVideoFormatDescriptionGetDimensions(current)
        // hvcC may also carry prefix/suffix SEI. A per-GOP user-data or HDR
        // message is not a decoder format change; its NAL stays in the sample.
        guard let parameters = decoderParameterSets(in: parsed, codec: codec),
              let oldParameters = decoderParameterSets(in: current, codec: codec),
              parameters != oldParameters || size.width != oldSize.width || size.height != oldSize.height else { return nil }

        // The parser supplies fresh geometry and VUI. Keep extra container
        // metadata (including Dolby configuration atoms) that the bitstream
        // does not replace, without restoring the previous SPS/PPS atom.
        var extensions = (CMFormatDescriptionGetExtensions(current) as? [String: Any]) ?? [:]
        for key in [kCMFormatDescriptionExtension_CleanAperture, kCMFormatDescriptionExtension_PixelAspectRatio,
                    kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                    kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionExtension_FullRangeVideo] {
            extensions.removeValue(forKey: key as String)
        }
        extensions.merge((CMFormatDescriptionGetExtensions(parsed) as? [String: Any]) ?? [:]) { _, new in new }
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = oldAtoms.merging(atoms) { _, new in new }
        var replacement: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
            width: size.width, height: size.height, extensions: extensions as CFDictionary, formatDescriptionOut: &replacement)
        return status == noErr ? replacement : nil
    }

    private static func decoderParameterSets(in description: CMFormatDescription, codec: CMVideoCodecType) -> Set<Data>? {
        let isHEVC = codec == kCMVideoCodecType_HEVC
        let required: Set<UInt8> = isHEVC ? [32, 33, 34] : [7, 8]
        var parameters = Set<Data>(), kinds = Set<UInt8>()
        var index = 0, count = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?, size = 0
            let status: OSStatus
            if isHEVC {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer, size > 0 else { return nil }
            let kind = isHEVC ? (pointer.pointee >> 1) & 0x3f : pointer.pointee & 0x1f
            if required.contains(kind) {
                kinds.insert(kind)
                parameters.insert(Data(bytes: pointer, count: size))
            }
            index += 1
        } while index < count
        return kinds.isSuperset(of: required) ? parameters : nil
    }

    static func makeFormatDescription(parameterSets: Data, codec: CMVideoCodecType,
                                      extensions: CFDictionary?) -> CMFormatDescription? {
        let isHEVC = codec == kCMVideoCodecType_HEVC
        guard isHEVC || codec == kCMVideoCodecType_H264 else { return nil }
        let units = annexBUnits(parameterSets).filter { unit in
            guard let first = unit.first else { return false }
            return isHEVC ? [32, 33, 34, 39, 40].contains((first >> 1) & 0x3f) : [7, 8].contains(first & 0x1f)
        }
        let kinds = Set(units.compactMap { unit in unit.first.map { isHEVC ? ($0 >> 1) & 0x3f : $0 & 0x1f } })
        guard isHEVC ? kinds.isSuperset(of: [32, 33, 34]) : kinds.isSuperset(of: [7, 8]) else { return nil }
        // Keep owned parameter sets alive for the entire native parser call.
        let allocated = units.map { unit -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: unit.count)
            unit.copyBytes(to: pointer, count: unit.count)
            return pointer
        }
        defer { allocated.forEach { $0.deallocate() } }
        let pointers = allocated.map { UnsafePointer<UInt8>($0) }
        let sizes = units.map(\.count)
        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                if isHEVC {
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: units.count, parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!, nalUnitHeaderLength: 4,
                        extensions: extensions, formatDescriptionOut: &description)
                } else {
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: units.count, parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                }
            }
        }
        return status == noErr ? description : nil
    }
}
