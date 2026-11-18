import simd

/// Conversion constants for UNORM textures, including the storage packing.
/// P010 stores ten-bit samples in bits 15...6; FFmpeg planar ten-bit stores
/// them in bits 9...0. Normalize the actual code maximum before range expansion.
struct YUVColorConversion {
    let matrix: simd_float3x3
    let offset: SIMD3<Float>
    let sampleScale: Float

    init(kr: Float, kb: Float, bitDepth: Int, leftShift: Int, fullRange: Bool) {
        let depth = min(16, max(8, bitDepth))
        let maximum = Float((1 << depth) - 1)
        // leftShift is the multiplier needed by the existing PixelBuffer API:
        // six means planar low bits; zero means native/P010 high bits.
        let storedShift = depth > 8 ? max(0, 16 - depth - leftShift) : 0
        sampleScale = Float(depth > 8 ? 65535 : 255) / (maximum * Float(1 << storedShift))
        let codeScale = Float(1 << (depth - 8))
        let lumaBlack: Float = fullRange ? 0 : 16 * codeScale
        let chromaCenter = Float(1 << (depth - 1))
        let lumaRange = fullRange ? maximum : 219 * codeScale
        let chromaRange = fullRange ? maximum : 224 * codeScale
        let yScale = maximum / lumaRange
        let cScale = maximum / chromaRange
        let kg = 1 - kr - kb
        offset = SIMD3<Float>(-lumaBlack / maximum, -chromaCenter / maximum, -chromaCenter / maximum)
        matrix = simd_float3x3([yScale, yScale, yScale],
            [0, -kb * (2 - 2 * kb) / kg * cScale, (2 - 2 * kb) * cScale],
            [(2 - 2 * kr) * cScale, -kr * (2 - 2 * kr) / kg * cScale, 0])
    }
}
