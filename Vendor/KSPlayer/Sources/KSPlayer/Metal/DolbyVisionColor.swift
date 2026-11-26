//
//  DolbyVisionColor.swift
//  KSPlayer
//
//  Build 42: per-frame Dolby Vision Profile 5 metadata, parsed from
//  FFmpeg's AV_FRAME_DATA_DOVI_METADATA side data (the RPU KSPlayer used
//  to read and discard in FFmpegDecode). The values are packed into a
//  flat float4 uniform block consumed by the `displayDolbyVisionTexture`
//  shader in Shaders.metal, which performs the same pipeline libplacebo
//  implements for mpv/SenPlayer: RPU reshaping -> IPT(YCC) to RGB matrix
//  in the PQ domain -> PQ EOTF -> LMS matrix -> BT.2390 tone mapping ->
//  BT.2020 to BT.709 gamut conversion for the SDR display.
//

import FFmpegKit
import Foundation
import simd

/// Reads a C fixed-size array field (imported into Swift as a tuple) as a
/// Swift array. The tuple layout is contiguous elements of one type.
private func doviArray<T, U>(_ field: T, count: Int, as _: U.Type) -> [U] {
    var copy = field
    return withUnsafePointer(to: &copy) { pointer in
        pointer.withMemoryRebound(to: U.self, capacity: count) {
            Array(UnsafeBufferPointer(start: $0, count: count))
        }
    }
}

public struct DolbyVisionFrameMetadata {
    /// Base-layer bit depth from the RPU header (10 for Profile 5).
    public let blBitDepth: Int
    /// Source peak as a PQ value in 0...1 (1.0 == 10000 nits).
    public let sourcePeakPQ: Float

    // Packed pieces of the shader uniform block (see uniformData).
    private let yccToRGBColumns: [SIMD4<Float>]
    private let yccOffset: SIMD3<Float>
    private let lmsColumns: [SIMD4<Float>]
    private let pivotLo: SIMD3<Float>
    private let pivotHi: SIMD3<Float>
    private let pivots: [SIMD4<Float>] // 9 slots: component * 3 + chunk
    private let numPivots: SIMD4<Float> // (n0, n1, n2, 0)
    private let coeffs: [SIMD4<Float>] // 24 slots: component * 8 + piece
    private let mmr: [SIMD4<Float>] // 144 slots: component * 48 + piece * 6 + order * 2 + half

    /// Total float4 slots in the packed uniform block (188 * 16 = 3008
    /// bytes, inside the 4 KB setFragmentBytes limit).
    static var uniformSlotCount: Int { 188 }

    /// ST.2084 inverse EOTF: linear light (1.0 == 10000 nits) -> PQ value.
    static func pqInverseEOTF(_ y: Double) -> Float {
        let m1 = 2610.0 / 16384.0
        let m2 = 2523.0 / 32.0
        let c1 = 3424.0 / 4096.0
        let c2 = 2413.0 / 128.0
        let c3 = 2392.0 / 128.0
        let y1 = pow(max(y, 0), m1)
        return Float(pow((c1 + c2 * y1) / (1.0 + c3 * y1), m2))
    }

    /// Packs the uniform block the Dolby shader reads as `constant float4*`.
    /// - Parameter inputScale: converts a normalized texture sample to the
    ///   reshaping domain (sample code / 2^blBitDepth); computed by the
    ///   renderer from the pixel buffer format, like YUVColorConversion.
    public func uniformData(inputScale: Float) -> Data {
        var slots = [SIMD4<Float>]()
        slots.reserveCapacity(Self.uniformSlotCount)
        slots.append(contentsOf: yccToRGBColumns) // 0..2
        slots.append(SIMD4(yccOffset.x, yccOffset.y, yccOffset.z, inputScale)) // 3
        slots.append(contentsOf: lmsColumns) // 4..6
        let displayPeakPQ = Self.pqInverseEOTF(100.0 / 10000.0) // SDR target: 100 nits
        slots.append(SIMD4(sourcePeakPQ, displayPeakPQ, 100.0 / 10000.0, 0)) // 7
        slots.append(SIMD4(pivotLo.x, pivotLo.y, pivotLo.z, 0)) // 8
        slots.append(SIMD4(pivotHi.x, pivotHi.y, pivotHi.z, 0)) // 9
        slots.append(contentsOf: pivots) // 10..18
        slots.append(numPivots) // 19
        slots.append(contentsOf: coeffs) // 20..43
        slots.append(contentsOf: mmr) // 44..187
        return slots.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<SIMD4<Float>>.stride)
        }
    }

    /// Parses one frame's AVDOVIMetadata side data. Returns nil when the
    /// header is out of range, so the caller falls back to the legacy path.
    public static func parse(_ metadata: UnsafeMutablePointer<AVDOVIMetadata>) -> DolbyVisionFrameMetadata? {
        let header = av_dovi_get_header(metadata).pointee
        let mapping = av_dovi_get_mapping(metadata).pointee
        let color = av_dovi_get_color(metadata).pointee
        let blBitDepth = Int(header.bl_bit_depth)
        guard (8 ... 16).contains(blBitDepth) else { return nil }
        let coefDenom = pow(2.0, Double(header.coef_log2_denom))
        let depthScale = 1.0 / Double(1 << blBitDepth)

        let curves = doviArray(mapping.curves, count: 3, as: AVDOVIReshapingCurve.self)
        var pivotsPacked = [SIMD4<Float>](repeating: .zero, count: 9)
        var coeffsPacked = [SIMD4<Float>](repeating: .zero, count: 24)
        var mmrPacked = [SIMD4<Float>](repeating: .zero, count: 144)
        var pivotLo = SIMD3<Float>(repeating: 0)
        var pivotHi = SIMD3<Float>(repeating: 1)
        var numPivotsValues = SIMD4<Float>(2, 2, 2, 0)

        for comp in 0 ..< 3 {
            let curve = curves[comp]
            let numPivots = max(2, min(9, Int(curve.num_pivots)))
            numPivotsValues[comp] = Float(numPivots)
            let pivotsRaw = doviArray(curve.pivots, count: 9, as: UInt16.self)
            var pivotsF = [Float](repeating: 0, count: 9)
            for i in 0 ..< numPivots {
                pivotsF[i] = Float(Double(pivotsRaw[i]) * depthScale)
            }
            for i in numPivots ..< 9 {
                pivotsF[i] = pivotsF[numPivots - 1]
            }
            pivotLo[comp] = pivotsF[0]
            pivotHi[comp] = pivotsF[numPivots - 1]
            for chunk in 0 ..< 3 {
                var slot = SIMD4<Float>(repeating: 0)
                for lane in 0 ..< 4 {
                    let index = chunk * 4 + lane
                    if index < 9 { slot[lane] = pivotsF[index] }
                }
                pivotsPacked[comp * 3 + chunk] = slot
            }

            let mappingIdcs = doviArray(curve.mapping_idc, count: 8, as: AVDOVIMappingMethod.self)
            let polyOrders = doviArray(curve.poly_order, count: 8, as: UInt8.self)
            let polyFlat = doviArray(curve.poly_coef, count: 24, as: Int64.self) // [piece][3]
            let mmrOrders = doviArray(curve.mmr_order, count: 8, as: UInt8.self)
            let mmrConstants = doviArray(curve.mmr_constant, count: 8, as: Int64.self)
            let mmrFlat = doviArray(curve.mmr_coef, count: 168, as: Int64.self) // [piece][order][7]
            for piece in 0 ..< 8 {
                let slot = comp * 8 + piece
                if mappingIdcs[piece].rawValue == 1 { // AV_DOVI_MAPPING_MMR
                    let order = max(1, min(3, Int(mmrOrders[piece])))
                    // (constant, order, 0, isMMR = 1)
                    coeffsPacked[slot] = SIMD4(Float(Double(mmrConstants[piece]) / coefDenom), Float(order), 0, 1)
                    for ord in 0 ..< 3 {
                        let base = (piece * 3 + ord) * 7
                        let c = (0 ..< 7).map { Float(Double(mmrFlat[base + $0]) / coefDenom) }
                        mmrPacked[comp * 48 + piece * 6 + ord * 2] = SIMD4(c[0], c[1], c[2], 0)
                        mmrPacked[comp * 48 + piece * 6 + ord * 2 + 1] = SIMD4(c[3], c[4], c[5], c[6])
                    }
                } else { // AV_DOVI_MAPPING_POLYNOMIAL: (c0, c1, c2, isMMR = 0)
                    let c0 = Float(Double(polyFlat[piece * 3]) / coefDenom)
                    let c1 = Float(Double(polyFlat[piece * 3 + 1]) / coefDenom)
                    let c2 = polyOrders[piece] >= 2 ? Float(Double(polyFlat[piece * 3 + 2]) / coefDenom) : 0
                    coeffsPacked[slot] = SIMD4(c0, c1, c2, 0)
                }
            }
        }

        func rational(_ value: AVRational) -> Float {
            value.den != 0 ? Float(Double(value.num) / Double(value.den)) : 0
        }
        let yccFlat = doviArray(color.ycc_to_rgb_matrix, count: 9, as: AVRational.self).map(rational)
        let offsetFlat = doviArray(color.ycc_to_rgb_offset, count: 3, as: AVRational.self).map(rational)
        let lmsFlat = doviArray(color.rgb_to_lms_matrix, count: 9, as: AVRational.self).map(rational)
        // BT.2020 LMS -> RGB (Hunt-Pointer-Estevez, no crosstalk), row-major,
        // precomposed with the RPU's rgb_to_lms so the shader applies one
        // matrix after the PQ EOTF — the composition libplacebo performs.
        let hpe: [Float] = [
            3.064396767855625, -2.165961226711146, 0.1015574148869036,
            -0.65613130540261551, 1.7855694129834121, -0.12943951030147041,
            0.017360633500538487, -0.047244531564539943, 1.0298894699757705,
        ]
        var lmsComposed = [Float](repeating: 0, count: 9)
        for row in 0 ..< 3 {
            for col in 0 ..< 3 {
                lmsComposed[row * 3 + col] = hpe[row * 3] * lmsFlat[col]
                    + hpe[row * 3 + 1] * lmsFlat[3 + col]
                    + hpe[row * 3 + 2] * lmsFlat[6 + col]
            }
        }
        // Row-major math matrix -> Metal columns (column j = math column j).
        func columns(of matrix: [Float]) -> [SIMD4<Float>] {
            (0 ..< 3).map { col in SIMD4(matrix[col], matrix[3 + col], matrix[6 + col], 0) }
        }
        let sourcePeakPQ = color.source_max_pq > 0
            ? Float(color.source_max_pq) / 4095.0
            : pqInverseEOTF(1000.0 / 10000.0)

        return DolbyVisionFrameMetadata(
            blBitDepth: blBitDepth,
            sourcePeakPQ: sourcePeakPQ,
            yccToRGBColumns: columns(of: yccFlat),
            yccOffset: SIMD3(offsetFlat[0], offsetFlat[1], offsetFlat[2]),
            lmsColumns: columns(of: lmsComposed),
            pivotLo: pivotLo,
            pivotHi: pivotHi,
            pivots: pivotsPacked,
            numPivots: numPivotsValues,
            coeffs: coeffsPacked,
            mmr: mmrPacked
        )
    }
}
