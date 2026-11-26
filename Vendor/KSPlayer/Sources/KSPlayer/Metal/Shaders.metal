//
//  Shaders.metal
#include <metal_stdlib>
using namespace metal;

struct VertexIn
{
    float4 pos [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct VertexOut {
    float4 renderedCoordinate [[position]];
    float2 textureCoordinate;
};

vertex VertexOut mapTexture(VertexIn input [[stage_in]]) {
    VertexOut outVertex;
    outVertex.renderedCoordinate = input.pos;
    outVertex.textureCoordinate = input.uv;
    return outVertex;
}

vertex VertexOut mapSphereTexture(VertexIn input [[stage_in]], constant float4x4& uniforms [[ buffer(2) ]]) {
    VertexOut outVertex;
    outVertex.renderedCoordinate = uniforms * input.pos;
    outVertex.textureCoordinate = input.uv;
    return outVertex;
}

fragment half4 displayTexture(VertexOut mappingVertex [[ stage_in ]],
                              texture2d<half, access::sample> texture [[ texture(0) ]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    return half4(texture.sample(s, mappingVertex.textureCoordinate));
}

fragment half4 displayYUVTexture(VertexOut in [[ stage_in ]],
                                  texture2d<half> yTexture [[ texture(0) ]],
                                  texture2d<half> uTexture [[ texture(1) ]],
                                  texture2d<half> vTexture [[ texture(2) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant float3& sampleScale [[ buffer(2) ]])
{
    half3 yuv;
    yuv.x = yTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.y = uTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.z = vTexture.sample(textureSampler, in.textureCoordinate).r;
    return half4(half3(yuvToBGRMatrix*(float3(yuv)*sampleScale+colorOffset)), half(1));
}


fragment half4 displayNV12Texture(VertexOut in [[ stage_in ]],
                                  texture2d<half> lumaTexture [[ texture(0) ]],
                                  texture2d<half> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant float3& sampleScale [[ buffer(2) ]])
{
    half3 yuv;
    yuv.x = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.yz = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;
    return half4(half3(yuvToBGRMatrix*(float3(yuv)*sampleScale+colorOffset)), half(1));
}

half3 shaderLinearize(half3 rgb) {
    rgb = pow(max(rgb,0), half3(4096.0/(2523 * 128)));
    rgb = max(rgb - half3(3424./4096), 0.0) / (half3(2413./4096 * 32) - half3(2392./4096 * 32) * rgb);
    rgb = pow(rgb, half3(4096.0 * 4 / 2610));
    return rgb;
}

half3 shaderDeLinearize(half3 rgb) {
    rgb = pow(max(rgb,0), half3(2610./4096 / 4));
    rgb = (half3(3424./4096) - half3(2413./4096 * 32) * rgb) / (half3(1.0) + half3(2392./4096 * 32) * rgb);
    rgb = pow(rgb, half3(2523./4096 * 128));
    return rgb;
}

// ---------------------------------------------------------------------------
// Build 42: Dolby Vision Profile 5 colour stage (libplacebo's pipeline).
// The uniform block is a flat float4 array packed by
// DolbyVisionFrameMetadata.uniformData in DolbyVisionColor.swift:
//   0..2   yccToRGB matrix columns      3     yccOffset.xyz, inputScale
//   4..6   LMS matrix columns           7     sourcePeakPQ, displayPeakPQ,
//                                             displayPeakNorm, unused
//   8      pivotLo                      9     pivotHi
//   10..18 reshaping pivots (3/component) 19   numPivots per component
//   20..43 per-piece coefficients       44..187 MMR coefficients
// ---------------------------------------------------------------------------

float doviPQToLinear(float e) {
    // ST 2084 EOTF: the first step raises the PQ signal to 1/m2
    // (32/2523), exactly as shaderLinearize above does. Build 42 shipped
    // this as m1 (2610/16384) — the exponent from the *inverse* EOTF —
    // which maps the whole real picture range to ~1e-6..1e-10 linear
    // (PQ 0.5 -> 1.8e-10 instead of 9.3e-3): a uniformly black picture
    // with healthy decode, metadata and presentation. Fixed in build 44.
    float e1 = pow(max(e, 0.0), 32.0 / 2523.0);
    return pow(max(e1 - 3424.0 / 4096.0, 0.0) / (2413.0 / 128.0 - 2392.0 / 128.0 * e1), 16384.0 / 2610.0);
}

float doviLinearToPQ(float y) {
    float y1 = pow(max(y, 0.0), 2610.0 / 16384.0);
    return pow((3424.0 / 4096.0 + 2413.0 / 128.0 * y1) / (1.0 + 2392.0 / 128.0 * y1), 2523.0 / 32.0);
}

float doviPivot(constant float4* p, int comp, int index) {
    return p[10 + comp * 3 + index / 4][index % 4];
}

float doviReshape(int comp, float3 sig, constant float4* p) {
    float s = sig[comp];
    int numPieces = int(p[19][comp] + 0.5) - 1;
    int piece = numPieces - 1;
    for (int i = 0; i < numPieces; i++) {
        if (s < doviPivot(p, comp, i + 1)) { piece = i; break; }
    }
    float4 coeffs = p[20 + comp * 8 + piece];
    if (coeffs.w < 0.5) {
        // Polynomial piece (order 1 or 2), Horner form.
        return clamp((coeffs.z * s + coeffs.y) * s + coeffs.x, 0.0, 1.0);
    }
    // MMR piece: constant + per-order dot products over sig, the pairwise
    // cross terms, and their powers — libplacebo's evaluation order.
    int order = int(coeffs.y + 0.5);
    int base = 44 + comp * 48 + piece * 6;
    float4 sigX = float4(sig.x * sig.y, sig.x * sig.z, sig.y * sig.z,
                         (sig.x * sig.y) * (sig.y * sig.z));
    float value = coeffs.x;
    value += dot(p[base].xyz, sig);
    value += dot(p[base + 1], sigX);
    if (order >= 2) {
        float3 sig2 = sig * sig;
        float4 sigX2 = sigX * sigX;
        value += dot(p[base + 2].xyz, sig2);
        value += dot(p[base + 3], sigX2);
        if (order >= 3) {
            value += dot(p[base + 4].xyz, sig2 * sig);
            value += dot(p[base + 5], sigX2 * sigX);
        }
    }
    return clamp(value, 0.0, 1.0);
}

// ITU-R BT.2390 EETF, applied in the PQ domain as libplacebo applies it
// (knee_offset = 1.0; source minimum is 0, so black adaptation is identity).
float doviToneMapPQ(float pq, float srcPeakPQ, float dstPeakPQ) {
    if (srcPeakPQ <= 0.0 || pq <= 0.0) { return pq; }
    float maxLum = dstPeakPQ / srcPeakPQ;
    float x = pq / srcPeakPQ;
    float ks = 2.0 * maxLum - 1.0;
    if (ks < 1.0) {
        float tb = clamp((x - ks) / (1.0 - ks), 0.0, 1.0);
        float tb2 = tb * tb;
        float tb3 = tb2 * tb;
        float pb = (2.0 * tb3 - 3.0 * tb2 + 1.0) * ks
                 + (tb3 - 2.0 * tb2 + tb) * (1.0 - ks)
                 + (-2.0 * tb3 + 3.0 * tb2) * maxLum;
        x = x < ks ? x : pb;
    }
    return x * srcPeakPQ;
}

fragment half4 displayDolbyVisionTexture(VertexOut in [[ stage_in ]],
                                         texture2d<half> lumaTexture [[ texture(0) ]],
                                         texture2d<half> chromaTexture [[ texture(1) ]],
                                         sampler textureSampler [[ sampler(0) ]],
                                         constant float4* dovi [[ buffer(0) ]])
{
    float3 ipt;
    ipt.x = float(lumaTexture.sample(textureSampler, in.textureCoordinate).r);
    ipt.yz = float2(chromaTexture.sample(textureSampler, in.textureCoordinate).rg);
    ipt *= dovi[3].w; // texture sample -> sample code / 2^bl_bit_depth

    // Reshaping operates on the full signal vector (MMR reads all three
    // components), clamped to each component's pivot range first.
    float3 sig = clamp(ipt, dovi[8].xyz, dovi[9].xyz);
    float3 reshaped = float3(doviReshape(0, sig, dovi),
                             doviReshape(1, sig, dovi),
                             doviReshape(2, sig, dovi));

    // IPT -> RGB in the PQ domain, then linearize and apply the LMS matrix
    // (RPU rgb_to_lms precomposed with the BT.2020 HPE LMS->RGB matrix).
    float3x3 yccToRGB = float3x3(dovi[0].xyz, dovi[1].xyz, dovi[2].xyz);
    float3 rgbPQ = yccToRGB * (reshaped - dovi[3].xyz);
    float3 linear = float3(doviPQToLinear(rgbPQ.x), doviPQToLinear(rgbPQ.y), doviPQToLinear(rgbPQ.z));
    float3x3 lmsMatrix = float3x3(dovi[4].xyz, dovi[5].xyz, dovi[6].xyz);
    linear = lmsMatrix * linear;

    // Tone map the peak component; scale every channel by the same ratio
    // in linear light so hue is preserved.
    float peak = max(max(linear.x, linear.y), linear.z);
    if (peak > 0.0) {
        float mappedPeak = doviPQToLinear(doviToneMapPQ(doviLinearToPQ(peak), dovi[7].x, dovi[7].y));
        linear *= mappedPeak / peak;
    }

    // Gamut-convert BT.2020 -> BT.709 (linear, D65), normalize to the
    // 100-nit SDR target, and encode sRGB for the layer.
    float3x3 gamut = float3x3(float3(1.660491, -0.124550, -0.018151),
                              float3(-0.587641, 1.132900, -0.100579),
                              float3(-0.072850, -0.008349, 1.118730));
    linear = gamut * linear;
    linear = clamp(linear / dovi[7].z, 0.0, 1.0);
    float3 srgb = mix(12.92 * linear,
                      1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055,
                      step(float3(0.0031308), linear));
    return half4(half3(srgb), half(1));
}

fragment half4 displayYCCTexture(VertexOut in [[ stage_in ]],
                                  texture2d<half> lumaTexture [[ texture(0) ]],
                                  texture2d<half> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant uchar3& leftShift [[ buffer(2) ]])
{
    half3 ipt;
    ipt.x = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    ipt.yz = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;
//    half3x3 ipt2lms = half3x3{{1, 0.1952, 0.4104}, {1, -0.2278, 0.2264}, {1, 0.0652, -1.3538}};
//    half3x3 lms2rgb = half3x3{{3.238998, -0.719461, -0.002862}, {-2.272734, 1.874998, -0.268066}, {0.086733, -0.158947, 1.074494}};
    half3x3 ipt2lms = half3x3{{1, 799/8192, 1681/8192}, {1, -933/8192, 1091/8192}, {1, 267/8192, -5545/8192}};
    half3x3 lms2rgb = half3x3{{3.43661, -0.79133, -0.0259499}, {-2.50645, 1.98360, -0.0989137}, {0.06984, -0.192271, 1.12486}};
    half3 lms = ipt2lms*ipt;
    lms = shaderLinearize(lms);
    half3 rgb = lms2rgb*lms;
    rgb = shaderDeLinearize(rgb);
    return half4(rgb, 1);
}
