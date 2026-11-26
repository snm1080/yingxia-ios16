//
//  MetalRender.swift
//  KSPlayer-iOS
//
//  Created by kintan on 2020/1/11.
//
import Accelerate
import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd

/// Immutable strong references bridge the command's asynchronous lifetime.
/// Pixel/texture bytes are not mutated after encoding on the main actor.
private final class MetalFrameResources: @unchecked Sendable {
    let pixelBuffer: PixelBufferProtocol
    let textures: [MTLTexture]
    init(pixelBuffer: PixelBufferProtocol, textures: [MTLTexture]) {
        self.pixelBuffer = pixelBuffer; self.textures = textures
    }
}

class MetalRender {
    static let device = MTLCreateSystemDefaultDevice()!
    static let library: MTLLibrary = {
        var library: MTLLibrary!
        library = device.makeDefaultLibrary()
        if library == nil {
            library = try? device.makeDefaultLibrary(bundle: .module)
        }
        return library
    }()

    private let renderPassDescriptor = MTLRenderPassDescriptor()
    private let commandQueue = MetalRender.device.makeCommandQueue()
    private let submissionGate = MetalFrameSubmissionGate()
    var hasCapacity: Bool { submissionGate.hasCapacity }
    private lazy var samplerState: MTLSamplerState? = {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        return MetalRender.device.makeSamplerState(descriptor: samplerDescriptor)
    }()

    @discardableResult func clear(drawable: CAMetalDrawable) -> Bool {
        guard submissionGate.begin() else { return false }
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            submissionGate.end()
            return false
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [submissionGate] _ in submissionGate.end() }
        commandBuffer.commit()
        return true
    }

    private lazy var dolbyPipeline10 = MetalRender.makePipelineState(fragmentFunction: "displayDolbyVisionTexture", bitDepth: 10)
    private lazy var dolbyPipeline8 = MetalRender.makePipelineState(fragmentFunction: "displayDolbyVisionTexture")

    private func dolbyPipelineState(bitDepth: Int32) -> MTLRenderPipelineState {
        bitDepth > 8 ? dolbyPipeline10 : dolbyPipeline8
    }

    @MainActor
    @discardableResult func draw(pixelBuffer: PixelBufferProtocol, display: DisplayEnum = .plane, drawable: CAMetalDrawable, dolbyVision: Data? = nil) -> Bool {
        guard submissionGate.begin() else { return false }
        let inputTextures = pixelBuffer.textures()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        guard !inputTextures.isEmpty, let commandBuffer = commandQueue?.makeCommandBuffer(), let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            submissionGate.end()
            return false
        }
        encoder.pushDebugGroup("RenderFrame")
        // Build 42: Dolby Vision frames (biplanar, plane display) take the
        // dedicated colour-stage pipeline; every other frame keeps the
        // existing pipeline and fragment buffers exactly.
        let useDolbyStage = dolbyVision != nil && display == .plane && pixelBuffer.planeCount == 2
        let state = useDolbyStage ? dolbyPipelineState(bitDepth: pixelBuffer.bitDepth) : display.pipeline(planeCount: pixelBuffer.planeCount, bitDepth: pixelBuffer.bitDepth)
        encoder.setRenderPipelineState(state)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        for (index, texture) in inputTextures.enumerated() {
            texture.label = "texture\(index)"
            encoder.setFragmentTexture(texture, index: index)
        }
        if useDolbyStage, let dolbyVision {
            dolbyVision.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress {
                    encoder.setFragmentBytes(baseAddress, length: dolbyVision.count, index: 0)
                }
            }
        } else {
            setFragmentBuffer(pixelBuffer: pixelBuffer, encoder: encoder)
        }
        display.set(encoder: encoder)
        encoder.popDebugGroup()
        encoder.endEncoding()
        commandBuffer.present(drawable)
        let resources = MetalFrameResources(pixelBuffer: pixelBuffer, textures: inputTextures)
        commandBuffer.addCompletedHandler { [resources, submissionGate] _ in
            withExtendedLifetime(resources) { submissionGate.end() }
        }
        commandBuffer.commit()
        return true
    }

    private func setFragmentBuffer(pixelBuffer: PixelBufferProtocol, encoder: MTLRenderCommandEncoder) {
        if pixelBuffer.planeCount > 1 {
            let yCbCrMatrix = pixelBuffer.yCbCrMatrix
            let coefficients: (Float, Float)
            if yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 {
                coefficients = (0.2126, 0.0722)
            } else if yCbCrMatrix == kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 {
                coefficients = (0.212, 0.087)
            } else if yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 {
                coefficients = (0.2627, 0.0593)
            } else {
                coefficients = (0.299, 0.114)
            }
            let conversion = YUVColorConversion(kr: coefficients.0, kb: coefficients.1,
                bitDepth: Int(pixelBuffer.bitDepth), leftShift: Int(pixelBuffer.leftShift), fullRange: pixelBuffer.isFullRangeVideo)
            var matrix = conversion.matrix
            var offset = conversion.offset
            var scale = SIMD3<Float>(repeating: conversion.sampleScale)
            encoder.setFragmentBytes(&matrix, length: MemoryLayout<simd_float3x3>.size, index: 0)
            encoder.setFragmentBytes(&offset, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
            encoder.setFragmentBytes(&scale, length: MemoryLayout<SIMD3<Float>>.size, index: 2)
        }
    }

    static func makePipelineState(fragmentFunction: String, isSphere: Bool = false, bitDepth: Int32 = 8) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.colorAttachments[0].pixelFormat = KSOptions.colorPixelFormat(bitDepth: bitDepth)
        descriptor.vertexFunction = library.makeFunction(name: isSphere ? "mapSphereTexture" : "mapTexture")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].bufferIndex = 1
        vertexDescriptor.attributes[1].offset = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<simd_float4>.stride
        vertexDescriptor.layouts[1].stride = MemoryLayout<simd_float2>.stride
        descriptor.vertexDescriptor = vertexDescriptor
        // swiftlint:disable force_try
        return try! library.device.makeRenderPipelineState(descriptor: descriptor)
        // swftlint:enable force_try
    }

    static func texture(pixelBuffer: CVPixelBuffer) -> [MTLTexture] {
        guard let iosurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return []
        }
        let formats = KSOptions.pixelFormat(planeCount: pixelBuffer.planeCount, bitDepth: pixelBuffer.bitDepth)
        return (0 ..< pixelBuffer.planeCount).compactMap { index in
            let width = pixelBuffer.widthOfPlane(at: index)
            let height = pixelBuffer.heightOfPlane(at: index)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: formats[index], width: width, height: height, mipmapped: false)
            return device.makeTexture(descriptor: descriptor, iosurface: iosurface, plane: index)
        }
    }

    static func textures(formats: [MTLPixelFormat], widths: [Int], heights: [Int], buffers: [MTLBuffer?], lineSizes: [Int]) -> [MTLTexture] {
        (0 ..< formats.count).compactMap { i in
            guard let buffer = buffers[i] else {
                return nil
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: formats[i], width: widths[i], height: heights[i], mipmapped: false)
            descriptor.storageMode = buffer.storageMode
            #if targetEnvironment(simulator)
            // MTLSimBuffer permits linear textures only on private buffers. Our
            // software frames are CPU-visible, so upload into a separate texture.
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            texture.replace(region: MTLRegionMake2D(0, 0, widths[i], heights[i]),
                            mipmapLevel: 0, withBytes: buffer.contents(), bytesPerRow: lineSizes[i])
            return texture
            #else
            return buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: lineSizes[i])
            #endif
        }
    }
}

// swiftlint:disable identifier_name
// private let kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 = vImage_YpCbCrToARGBMatrix(Kr: 0.299, Kb: 0.114)
// private let kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 = vImage_YpCbCrToARGBMatrix(Kr: 0.2126, Kb: 0.0722)
private let kvImage_YpCbCrToARGBMatrix_SMPTE_240M_1995 = vImage_YpCbCrToARGBMatrix(Kr: 0.212, Kb: 0.087)
private let kvImage_YpCbCrToARGBMatrix_ITU_R_2020 = vImage_YpCbCrToARGBMatrix(Kr: 0.2627, Kb: 0.0593)
extension vImage_YpCbCrToARGBMatrix {
    /**
     https://en.wikipedia.org/wiki/YCbCr
     @textblock
            | R |    | 1    0                                                            2-2Kr |   | Y' |
            | G | = | 1   -Kb * (2 - 2 * Kb) / Kg   -Kr * (2 - 2 * Kr) / Kg |  | Cb |
            | B |    | 1   2 - 2 * Kb                                                     0  |  | Cr |
     @/textblock
     */
    init(Kr: Float, Kb: Float) {
        let Kg = 1 - Kr - Kb
        self.init(Yp: 1, Cr_R: 2 - 2 * Kr, Cr_G: -Kr * (2 - 2 * Kr) / Kg, Cb_G: -Kb * (2 - 2 * Kb) / Kg, Cb_B: 2 - 2 * Kb)
    }

    var videoRange: vImage_YpCbCrToARGBMatrix {
        vImage_YpCbCrToARGBMatrix(Yp: 255 / 219 * Yp, Cr_R: 255 / 224 * Cr_R, Cr_G: 255 / 224 * Cr_G, Cb_G: 255 / 224 * Cb_G, Cb_B: 255 / 224 * Cb_B)
    }

    var buffer: MTLBuffer? {
        var matrix = simd_float3x3([Yp, Yp, Yp], [0.0, Cb_G, Cb_B], [Cr_R, Cr_G, 0.0])
        let buffer = MetalRender.device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }
}

// swiftlint:enable identifier_name
