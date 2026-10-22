//
//  DrawableVideoDecoder.swift
//  Moonlight Vision
//
//  Created by tht7 on 30/12/2024. Updated 2026/02/28 by Linggan-ua.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Moonlight
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore // For CADisplayLink
import RealityKit
import SwiftUI
import Synchronization
import VideoToolbox
import CoreFoundation

// Add these constants after your existing constants
let kCVPixelBufferYCbCrMatrixKey = "YCbCrMatrix" as CFString
let kCVPixelBufferColorPrimariesKey = "ColorPrimaries" as CFString
let kCVPixelBufferTransferFunctionKey = "TransferFunction" as CFString

struct HDRParams {
    var boost: Float
    var contrast: Float
    var saturation: Float
    var brightness: Float
    /// PQ / ST.2084 HDR exposure trim (RealityKit path); ignored for SDR frames.
    var pqExposure: Float
    var mode: Int32  // 0 = Power Curve, 1 = ACES, 2 = ACES + Vibrance
}

private struct ColorEnhancementUniforms {
    var saturation: Float
    var contrast: Float
    var warmth: Float
    var padding1: Float
}

private struct ShaderFullHDRParams {
    var boost: Float
    var contrast: Float
    var saturation: Float
    var brightness: Float
    var pqExposure: Float
    var mode: Int32
}

let kCVImageBufferYCbCrMatrix_ITU_R_2020 = "ITU_R_2020" as CFString
let kCVImageBufferColorPrimaries_ITU_R_2020 = "ITU_R_2020" as CFString
let kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ = "SMPTE_ST_2084_PQ" as CFString

let kCVImageBufferColorPrimaries_ITU_R_709_2 = "ITU_R_709_2" as CFString
let kCVImageBufferColorPrimaries_SMPTE_C = "SMPTE_C" as CFString
let kCVImageBufferYCbCrMatrix_ITU_R_709_2 = "ITU_R_709_2" as CFString

/// A Bool written on the main thread and read per frame on the VT output thread.
final class ThreadSafeFlag: Sendable {
    private let storage: Atomic<Bool>
    init(_ value: Bool) { storage = Atomic(value) }
    var value: Bool {
        get { storage.load(ordering: .relaxed) }
        set { storage.store(newValue, ordering: .relaxed) }
    }
}

// MARK: - VideoDecoderRenderer

@objc
class DrawableVideoDecoder: NSObject, AnyVideoDecoderRenderer {
    // MARK: - Properties

    private var callbacks: ConnectionCallbacks

    let callbackToRender: @MainActor (TextureResource.DrawableQueue, TextureResource.DrawableQueue?, (Int, Int)?) -> Void
    let debugInfoCallback: (@MainActor (String) -> Void)?
    private var hdrSettingsProvider: (() -> HDRParams)? = nil

    /// Format and frame info
    private var videoFormat: Int32 = 0
    private var frameRate: Int32 = 0
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0

    private var metalFormat: MTLPixelFormat
    private var decodingFormat: OSType

    /// If true, we'll do pacing logic in displayLink
    private var framePacing: Bool = false

    /// Parameter sets (VPS/SPS/PPS) collected for the next IDR's format description.
    /// NSData keeps each buffer at a stable address while CoreMedia reads it.
    private var parameterSetBuffers: [NSData] = []

    /// HDR metadata
    private var masteringDisplayColorVolume: Data?
    private var contentLightLevelInfo: Data?

    /// Video format description, used when creating sample buffers
    private var formatDesc: CMVideoFormatDescription?

    /// Display link for pacing decode submissions
    private var displayLink: CADisplayLink?

    var textureCache: CVMetalTextureCache?
    var drawableQueue: TextureResource.DrawableQueue?
    var ambilightQueue: TextureResource.DrawableQueue?
    var enableAmbilight: Bool = true

    private var session: VTDecompressionSession?
    private var decoderCallback: VTDecompressionOutputCallbackRecord
    /// Full-range flag from the current format description, for pixel formats that don't encode
    /// the range. Written before the session that reads it is created.
    private var formatIsFullRange = false

    /// Guards the decode-side state (session, formatDesc, parameter sets, HDR metadata, isStopped).
    /// submitDecodeBuffer and setHdrMode run on the main thread; stop() runs on the connection
    /// thread. Never taken on the VT output thread, so draining a session under it can't deadlock.
    private let decodeLock = NSLock()
    private var isStopped = false
    
    private let inflightSemaphore = DispatchSemaphore(value: 3)

    /// Checked on the VT output thread before each frame touches the drawable queues.
    private let renderGate = Atomic<Bool>(true)

    /// Per-frame render gate. Closing it makes decoded frames drop instead of rendering; stop()
    /// closes it first thing, and stream teardown can close it earlier from any thread.
    var isRenderingEnabled: Bool {
        get { renderGate.load(ordering: .acquiring) }
        set { renderGate.store(newValue, ordering: .releasing) }
    }

    lazy var mtlDevice: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError()
        }
        return device
    }()

    private lazy var commandQueue: MTLCommandQueue? = mtlDevice.makeCommandQueue()

    private var hdrEnabled: Bool

    // The providers below are called per frame on the VT output thread, so they must not touch
    // main-actor state; read from a thread-safe snapshot such as ThreadSafeFlag instead.
    private var enhancementsProvider: (() -> (Float, Float, Float))? = nil
    private var isVolumeModeProvider: (() -> Bool)? = nil
    private var enableAmbilightProvider: (() -> Bool)? = nil

    private var copyPipelineState: MTLRenderPipelineState?
    private var copyPipelineStateYUV: MTLRenderPipelineState?
    private var lastCopyFragment: String?
    private var ambilightPipelineState: MTLRenderPipelineState?

    private var pixelFormatTraits: PixelFormatTraits?

    private var firstFrameEmitted = false
    private var lastAmbilightLogTime = Date.distantPast
    private var prevAmbilightTexture: MTLTexture?

    // MARK: - Initialization

    init(
        callbacks: ConnectionCallbacks,
        useFramePacing: Bool,
        enableHDR: Bool = false,
        hdrSettingsProvider: (() -> HDRParams)? = nil,
        enhancementsProvider: (() -> (Float, Float, Float))? = nil,
        isVolumeModeProvider: (() -> Bool)? = nil,
        enableAmbilightProvider: (() -> Bool)? = nil,
        callbackToRender: @MainActor @escaping (TextureResource.DrawableQueue, TextureResource.DrawableQueue?, (Int, Int)?) -> Void,
        debugInfoCallback: (@MainActor (String) -> Void)? = nil
    ) {
        metalFormat = enableHDR ? .rgba16Float : .bgra8Unorm_srgb

        decodingFormat = enableHDR ?
            kCVPixelFormatType_64RGBAHalf :
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        self.callbacks = callbacks
        framePacing = useFramePacing
        self.hdrEnabled = enableHDR
        self.hdrSettingsProvider = hdrSettingsProvider
        self.enhancementsProvider = enhancementsProvider
        self.isVolumeModeProvider = isVolumeModeProvider
        self.enableAmbilightProvider = enableAmbilightProvider
        self.callbackToRender = callbackToRender
        self.debugInfoCallback = debugInfoCallback

        decoderCallback = VTDecompressionOutputCallbackRecord()
        decoderCallback.decompressionOutputCallback = { decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            let mySelf = Unmanaged<DrawableVideoDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
            mySelf.decompressionOutputCallback(
                decompressionOutputRefCon: decompressionOutputRefCon,
                sourceFrameRefCon: sourceFrameRefCon,
                status: status,
                infoFlags: infoFlags,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                presentationDuration: presentationDuration
            )
        }

        super.init()
    }

    func decompressionOutputCallback(
        decompressionOutputRefCon _: UnsafeMutableRawPointer?,
        sourceFrameRefCon _: UnsafeMutableRawPointer?,
        status _: OSStatus,
        infoFlags _: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp _: CMTime,
        presentationDuration _: CMTime?
    ) {
        guard let imageBuffer = imageBuffer, isRenderingEnabled else { return }
        
        if inflightSemaphore.wait(timeout: .now()) != .success {
            return
        }
        
        autoreleasepool {
            _renderFrame(imageBuffer: imageBuffer)
        }
    }
    
    private func _renderFrame(imageBuffer: CVImageBuffer) {
        guard
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let textureCache = textureCache
        else {
            inflightSemaphore.signal()
            return
        }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }

        let pf = CVPixelBufferGetPixelFormatType(imageBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(imageBuffer)

        let traits: PixelFormatTraits
        if let cached = pixelFormatTraits, cached.pixelFormat == pf {
            traits = cached
        } else {
            traits = PixelFormatTraits(pixelFormat: pf)
            pixelFormatTraits = traits
        }
        let looksLikeBt2020TenBitStream = traits.isTenBit

        // PQ must follow the **frame** transfer function. Never force PQ just because the user enabled
        // "HDR display mode" — that was decoding SDR streams through pqInv() (too dark) while true PQ
        // still looked wrong next to the mistaken baseline.
        var isPQ = false
        if let tfVal = CVBufferGetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, nil)?.takeUnretainedValue(),
           CFGetTypeID(tfVal) == CFStringGetTypeID() {
            isPQ = CFEqual(tfVal as! CFString, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        } else if hdrEnabled {
            isPQ = looksLikeBt2020TenBitStream
        }

        var primariesType: UInt32 = 0 // 0=709, 1=2020, 2=SMPTE-C(601)
        if let primVal = CVBufferGetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, nil)?.takeUnretainedValue(),
           CFGetTypeID(primVal) == CFStringGetTypeID() {
            let prim = primVal as! CFString
            if CFEqual(prim, kCVImageBufferColorPrimaries_ITU_R_2020) {
                primariesType = 1
            } else if CFEqual(prim, kCVImageBufferColorPrimaries_ITU_R_709_2) {
                primariesType = 0
            } else if CFEqual(prim, kCVImageBufferColorPrimaries_SMPTE_C) {
                primariesType = 2
            }
        } else {
            primariesType = looksLikeBt2020TenBitStream ? 1 : 0
        }

        var matrixType: UInt32 = 0 // 0=709, 1=2020, 2=601
        if let mtxVal = CVBufferGetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue(),
           CFGetTypeID(mtxVal) == CFStringGetTypeID() {
            let mtx = mtxVal as! CFString
            if CFEqual(mtx, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
                matrixType = 1
            } else if CFEqual(mtx, "ITU_R_601_4" as CFString) {
                matrixType = 2
            } else {
                matrixType = 0
            }
        } else {
            matrixType = looksLikeBt2020TenBitStream ? 1 : 0
        }

        let isFullRangeSource = traits.isFullRange ?? formatIsFullRange

        guard
            let drawable = try? drawableQueue?.nextDrawable()
        else {
            commandBuffer.commit()
            return
        }

        // Avoid private "secret" SDR texture formats that may apply
        // undocumented color transforms. Use explicit YUV planes instead.
        let isBiPlanar = planeCount >= 2
        let yFormat: MTLPixelFormat = hdrEnabled ? .r16Unorm : .r8Unorm
        let cbcrFormat: MTLPixelFormat = hdrEnabled ? .rg16Unorm : .rg8Unorm

        if !firstFrameEmitted {
            let fmtStr = CVMetalHelpers.coreVideoPixelFormatToStr[pf] ?? "\(pf)"
            print("[DrawableVideoDecoder] PF=\(fmtStr), planes=\(planeCount), hdr=\(hdrEnabled), PQ=\(isPQ), fullRange=\(isFullRangeSource), primariesType=\(primariesType), matrixType=\(matrixType)")
            let debugLine = "Codec \(codecDescription(videoFormat)) | PF \(fmtStr) | planes \(planeCount) | \(isBiPlanar ? "YUV" : "RGB") | \(isFullRangeSource ? "full" : "limited") | Matrix:\(matrixType) | PQ \(isPQ ? "yes" : "no")"
            DispatchQueue.main.async { [debugInfoCallback] in
                debugInfoCallback?(debugLine)
            }
        }

        let fragment: String = isBiPlanar ? "copyFragmentShaderHDR_EDR" : "copyFragmentShaderHEVC_EDR"

        let pipelineState: MTLRenderPipelineState
        if let cached = isBiPlanar ? copyPipelineStateYUV : copyPipelineState, lastCopyFragment == fragment {
            pipelineState = cached
        } else if let built = buildCopyPipeline(fragment: fragment) {
            if isBiPlanar { copyPipelineStateYUV = built } else { copyPipelineState = built }
            lastCopyFragment = fragment
            pipelineState = built
        } else {
            print("DrawableVideoDecoder: Failed to build \(isBiPlanar ? "YUV" : "single-plane") pipeline")
            commandBuffer.commit()
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .dontCare
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        if isBiPlanar {
            let w0 = CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
            let h0 = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
            let w1 = CVPixelBufferGetWidthOfPlane(imageBuffer, 1)
            let h1 = CVPixelBufferGetHeightOfPlane(imageBuffer, 1)

            var yTexRef: CVMetalTexture?
            var cbcrTexRef: CVMetalTexture?

            let res0 = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, imageBuffer, nil,
                yFormat, w0, h0, 0, &yTexRef
            )
            let res1 = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, imageBuffer, nil,
                cbcrFormat, w1, h1, 1, &cbcrTexRef
            )
            if res0 != 0 || res1 != 0 {
                renderEncoder.endEncoding()
                commandBuffer.commit()
                return
            }

            guard let yTex = yTexRef.flatMap(CVMetalTextureGetTexture),
                  let cbcrTex = cbcrTexRef.flatMap(CVMetalTextureGetTexture) else {
                renderEncoder.endEncoding()
                commandBuffer.commit()
                return
            }

            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setFragmentTexture(yTex, index: 0)
            renderEncoder.setFragmentTexture(cbcrTex, index: 1)
        } else {
            var imageTexture: CVMetalTexture?
            let w = CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
            let h = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
            let srcFormat = CVMetalHelpers.getTextureTypesForFormat(pf)[0]

            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, imageBuffer, nil,
                srcFormat, w, h, 0, &imageTexture
            )
            guard result == 0, let imageTexture, let sourceTexture = CVMetalTextureGetTexture(imageTexture) else {
                renderEncoder.endEncoding()
                commandBuffer.commit()
                return
            }

            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setFragmentTexture(sourceTexture, index: 0)
        }

        struct ShaderHDRParams { var is10Bit: UInt32; var isFullRange: UInt32; var isPQ: UInt32; var matrixType: UInt32; var primariesType: UInt32; var isTargetDisplayP3: UInt32 }
        
        var shaderParams = ShaderHDRParams(
            is10Bit: traits.isTenBit ? 1 : 0,
            isFullRange: isFullRangeSource ? 1 : 0,
            isPQ: isPQ ? 1 : 0,
            matrixType: matrixType,
            primariesType: primariesType,
            isTargetDisplayP3: hdrEnabled ? 1 : 0
        )
        
        renderEncoder.setFragmentBytes(&shaderParams, length: MemoryLayout<ShaderHDRParams>.size, index: 0)

        let full = hdrSettingsProvider?() ?? HDRParams(
            boost: 1.0, contrast: 1.0, saturation: 1.0, brightness: 0.0, pqExposure: 1.0, mode: 1
        )
        var fullParams = ShaderFullHDRParams(
            boost: full.boost,
            contrast: full.contrast,
            saturation: full.saturation,
            brightness: full.brightness,
            pqExposure: full.pqExposure,
            mode: full.mode
        )
        renderEncoder.setFragmentBytes(&fullParams, length: MemoryLayout<ShaderFullHDRParams>.size, index: 1)

        let satConWarm = enhancementsProvider?() ?? (1.0, 1.0, 0.0)
        var enh = ColorEnhancementUniforms(saturation: satConWarm.0, contrast: satConWarm.1, warmth: satConWarm.2, padding1: 0)
        renderEncoder.setFragmentBytes(&enh, length: MemoryLayout<ColorEnhancementUniforms>.size, index: 2)

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.generateMipmaps(for: drawable.texture)
            blitEncoder.endEncoding()
        }
        
        let ambEnabled = enableAmbilightProvider?() ?? enableAmbilight
        if let ambQueue = ambilightQueue, ambEnabled, let ambDrawable = try? ambQueue.nextDrawable() {
            let targetMipLevel = 6
            let mipLevel = min(targetMipLevel, drawable.texture.mipmapLevelCount - 1)
            
            if ambilightPipelineState == nil {
                ambilightPipelineState = buildCopyPipeline(fragment: "copyFragmentShaderAmbilight")
            }
            
            if prevAmbilightTexture == nil || prevAmbilightTexture!.width != ambDrawable.texture.width || prevAmbilightTexture!.height != ambDrawable.texture.height {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ambDrawable.texture.pixelFormat, width: ambDrawable.texture.width, height: ambDrawable.texture.height, mipmapped: false)
                desc.usage = [.shaderRead, .renderTarget]
                prevAmbilightTexture = mtlDevice.makeTexture(descriptor: desc)
            }
            
            if let ambPipelineState = ambilightPipelineState {
                let ambRenderPass = MTLRenderPassDescriptor()
                ambRenderPass.colorAttachments[0].texture = ambDrawable.texture
                ambRenderPass.colorAttachments[0].loadAction = .dontCare
                ambRenderPass.colorAttachments[0].storeAction = .store
                
                if let ambRenderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: ambRenderPass) {
                    ambRenderEncoder.setRenderPipelineState(ambPipelineState)
                    
                    var isVolumeInt: Int32 = (self.isVolumeModeProvider?() ?? false) ? 1 : 0
                    ambRenderEncoder.setFragmentBytes(&isVolumeInt, length: MemoryLayout<Int32>.size, index: 1)
                    
                    if let mipTextureView = drawable.texture.makeTextureView(pixelFormat: drawable.texture.pixelFormat, textureType: .type2D, levels: mipLevel..<mipLevel+1, slices: 0..<1) {
                        ambRenderEncoder.setFragmentTexture(mipTextureView, index: 0)
                        ambRenderEncoder.setFragmentTexture(self.prevAmbilightTexture, index: 1)
                        ambRenderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                        
                        let now = Date()
                        if now.timeIntervalSince(self.lastAmbilightLogTime) > 5.0 {
                            print("[Ambilight] Rendered frame. isVolumeMode: \(isVolumeInt == 1). MipLevel: \(mipLevel)")
                            self.lastAmbilightLogTime = now
                        }
                    }
                    ambRenderEncoder.endEncoding()
                }
                
                if let blitEncoder = commandBuffer.makeBlitCommandEncoder(), let prevTex = self.prevAmbilightTexture {
                    blitEncoder.copy(from: ambDrawable.texture, to: prevTex)
                    blitEncoder.endEncoding()
                }
            }
            
            commandBuffer.present(ambDrawable)
        }

        // Present via the command buffer so RealityKit only sees the drawables once the GPU work
        // above has completed; a bare present() hands over textures the GPU may still be writing.
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if !firstFrameEmitted {
            firstFrameEmitted = true
            DispatchQueue.main.async {
                self.callbacks.videoContentShown()
                print("DrawableVideoDecoder: First frame presented (PQ=\(isPQ), primariesType=\(primariesType), matrixType=\(matrixType))")
            }
        }
    }

    func setupLowLevelTexture() {
        DispatchQueue.main.sync {
            if videoWidth == 0 || videoHeight == 0 {
                print("Tried to set up client texture without defined dimensions (\(videoWidth), \(videoHeight)) - skipping")
                return
            }

            self.drawableQueue = {
                let descriptor = TextureResource.DrawableQueue.Descriptor(
                    pixelFormat: metalFormat,
                    width: Int(videoWidth),
                    height: Int(videoHeight),
                    usage: [.renderTarget, .shaderRead],
                    mipmapsMode: .allocateAll
                )
                do {
                    let queue = try TextureResource.DrawableQueue(descriptor)
                    queue.allowsNextDrawableTimeout = true
                    return queue
                } catch {
                    fatalError("Could not create DrawableQueue: \(error)")
                }
            }()

            self.ambilightQueue = {
                let targetMipLevel = 6
                let ambWidth = max(1, Int(videoWidth) >> targetMipLevel)
                let ambHeight = max(1, Int(videoHeight) >> targetMipLevel)
                
                let descriptor = TextureResource.DrawableQueue.Descriptor(
                    pixelFormat: metalFormat,
                    width: ambWidth,
                    height: ambHeight,
                    usage: [.renderTarget, .shaderWrite, .shaderRead],
                    mipmapsMode: .none
                )
                do {
                    let queue = try TextureResource.DrawableQueue(descriptor)
                    queue.allowsNextDrawableTimeout = true
                    return queue
                } catch {
                    print("Could not create Ambilight DrawableQueue: \(error)")
                    return nil
                }
            }()

            self.callbackToRender(self.drawableQueue!, self.ambilightQueue, (videoWidth, videoHeight))
        }
    }

    func setup(withVideoFormat videoFormat: Int32, width videoWidth: Int32, height videoHeight: Int32, frameRate: Int32) {
        self.videoFormat = videoFormat
        self.frameRate = frameRate
        self.videoWidth = Int(videoWidth)
        self.videoHeight = Int(videoHeight)
        print("DrawableVideoDecoder: setup format=\(String(format: "0x%04X", videoFormat)) [\(codecDescription(videoFormat))] \(videoWidth)x\(videoHeight)@\(frameRate)")

        let cacheAttributes: [String: Any] = [
            kCVMetalTextureCacheMaximumTextureAgeKey as String: 1,
        ]

        let textureAttributes: [String: Any] = {
            var attrs: [String: Any] = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
            ]
            if hdrEnabled {
                attrs[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            } else {
                attrs[kCVPixelBufferPixelFormatTypeKey as String] = decodingFormat
            }
            return attrs
        }()

        let res = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            cacheAttributes as CFDictionary,
            mtlDevice,
            textureAttributes as CFDictionary,
            &textureCache
        )

        if res != kCVReturnSuccess {
            print("Creating texture cache failed \(res)")
        }

        setupLowLevelTexture()
    }

    func start() {
        print("DrawableVideoDecoder: start() display link")
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback(_:)))
        if #available(iOS 15.0, tvOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(frameRate),
                maximum: Float(frameRate),
                preferred: Float(frameRate)
            )
        } else {
            displayLink?.preferredFramesPerSecond = Int(frameRate)
        }

        displayLink?.add(to: .main, forMode: .default)
    }

    func stop() {
        print("DrawableVideoDecoder: stop()")
        isRenderingEnabled = false
        displayLink?.invalidate()
        displayLink = nil

        // The display link may still be mid-callback on main, so mark the decoder stopped
        // before draining: a late IDR must not create a fresh session after this point.
        decodeLock.lock()
        isStopped = true
        let oldSession = session
        session = nil
        formatDesc = nil
        parameterSetBuffers.removeAll()
        masteringDisplayColorVolume = nil
        contentLightLevelInfo = nil
        decodeLock.unlock()

        // After this no output callback is running or pending, so the render state below is ours.
        if let oldSession {
            invalidate(oldSession)
        }
        pixelFormatTraits = nil
        formatIsFullRange = false

        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        textureCache = nil
        copyPipelineState = nil
        copyPipelineStateYUV = nil
        lastCopyFragment = nil
        
        // Reset so the next connection (reconnect) can fire videoContentShown again.
        firstFrameEmitted = false
        
        print("DrawableVideoDecoder: Stopped and cleaned up all state")
    }

    // MARK: - Rendering Loop

    @objc private func displayLinkCallback(_ sender: CADisplayLink) {
        var handle: VIDEO_FRAME_HANDLE?
        var du: PDECODE_UNIT?

        while LiPollNextVideoFrame(&handle, &du) {
            guard let handle = handle, let du = du else {
                continue
            }

            let result = DrSubmitDecodeUnit(du)
            LiCompleteVideoFrame(handle, result)

            if framePacing && frameRate <= 60 {
                let displayRefreshRate = 1.0 / (sender.targetTimestamp - sender.timestamp)
                if displayRefreshRate >= Double(frameRate) * 0.9 {
                    if LiGetPendingVideoFrames() == 1 {
                        break
                    }
                }
            }
        }
    }

    // MARK: - Decoding & Sample Buffer Handling

    @discardableResult
    @objc(submitDecodeBuffer:length:bufferType:decodeUnit:)
    func submitDecodeBuffer(
        _ dataPtr: UnsafeMutablePointer<UInt8>!,
        length: Int32,
        bufferType: Int32,
        decode decodeUnit: PDECODE_UNIT!
    ) -> Int32 {
        decodeLock.lock()
        defer { decodeLock.unlock() }

        guard !isStopped else {
            // Picture data is ours to free; parameter sets belong to the library.
            if bufferType == BUFFER_TYPE_PICDATA { free(dataPtr) }
            return DR_OK
        }
        return submitDecodeBufferLocked(dataPtr, length: length, bufferType: bufferType, decodeUnit: decodeUnit)
    }

    private func submitDecodeBufferLocked(
        _ dataPtr: UnsafeMutablePointer<UInt8>,
        length: Int32,
        bufferType: Int32,
        decodeUnit: PDECODE_UNIT
    ) -> Int32 {
        if decodeUnit.pointee.frameType == FRAME_TYPE_IDR {
            if bufferType != BUFFER_TYPE_PICDATA {
                if bufferType == BUFFER_TYPE_VPS
                    || bufferType == BUFFER_TYPE_SPS
                    || bufferType == BUFFER_TYPE_PPS
                {
                    let startLen = (dataPtr[2] == 0x01) ? 3 : 4
                    parameterSetBuffers.append(NSData(bytes: dataPtr + startLen, length: Int(length) - startLen))
                }
                return DR_OK
            }

            if let formatDesc = recreateFormatDescriptionForIDR(
                dataPtr: dataPtr, length: length
            ) {
                // Drain and tear down the previous session before its replacement exists, so
                // output callbacks never overlap and the old session isn't leaked.
                if let oldSession = session {
                    session = nil
                    invalidate(oldSession)
                }

                self.formatDesc = formatDesc
                formatIsFullRange = CVMetalHelpers.getIsFullRangeForVideoFormat(formatDesc)
                let decoderConfiguration: [String: Any] = [
                    kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
                ]
                
                var attributes: [CFString: Any] = [
                    kCVPixelBufferMetalCompatibilityKey: true,
                    kCVPixelBufferPoolMinimumBufferCountKey: 3
                ]
                if hdrEnabled {
                    attributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                } else {
                    if (self.videoFormat & VIDEO_FORMAT_MASK_AV1) != 0 {
                        attributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_Lossless_32BGRA
                    } else {
                        attributes[kCVPixelBufferPixelFormatTypeKey] = decodingFormat
                    }
                }
                
                // The session's callback holds a strong reference to us, released in invalidate(_:),
                // so a late callback can never see a freed decoder.
                let refCon = Unmanaged.passRetained(self)
                var outputCallback = decoderCallback
                outputCallback.decompressionOutputRefCon = refCon.toOpaque()
                let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: formatDesc, decoderSpecification: decoderConfiguration as CFDictionary, imageBufferAttributes: attributes as CFDictionary, outputCallback: &outputCallback, decompressionSessionOut: &session)
                if status != noErr {
                    print("VTDecompressionSessionCreate failed: \(status)")
                    session = nil
                    refCon.release()
                }

                AudioHelpers.fixAudioForSurroundForCurrentWindow()
            } else {
                free(dataPtr)
                return DR_NEED_IDR
            }
        }

        guard let formatDesc = formatDesc else {
            free(dataPtr)
            return DR_NEED_IDR
        }

        // Takes ownership of dataPtr, including on failure.
        guard let sampleBuffer = createSampleBuffer(
            dataPtr: dataPtr,
            length: Int(length),
            formatDesc: formatDesc,
            decodeUnit: decodeUnit
        ) else {
            return DR_NEED_IDR
        }

        guard let activeSession = session else {
            return DR_NEED_IDR
        }
        
        VTDecompressionSessionDecodeFrame(activeSession, sampleBuffer: sampleBuffer, flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil)

        // Only signal first-shown once per connection session.
        // firstFrameEmitted covers the render-path notification; this covers
        // the decode-path (IDR arrival) so the UI unblocks even before the
        // first frame is composited.  Subsequent IDR frames (error recovery)
        // must NOT re-fire the callback or they flood onChange observers.
        if decodeUnit.pointee.frameType == FRAME_TYPE_IDR && !firstFrameEmitted {
            callbacks.videoContentShown()
        }

        return DR_OK
    }

    // MARK: - Helper: Recreate Format Description for IDR

    /// Waits for the session's in-flight frames, then tears it down and drops the decoder
    /// reference its output callback held.
    private func invalidate(_ session: VTDecompressionSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        Unmanaged.passUnretained(self).release()
    }

    private func recreateFormatDescriptionForIDR(
        dataPtr: UnsafeMutablePointer<UInt8>,
        length: Int32
    ) -> CMVideoFormatDescription? {
        formatDesc = nil

        if (videoFormat & VIDEO_FORMAT_MASK_H264) != 0 {
            return createH264FormatDescription()
        } else if (videoFormat & VIDEO_FORMAT_MASK_H265) != 0 {
            return createHEVCFormatDescription()
        } else if (videoFormat & VIDEO_FORMAT_MASK_AV1) != 0 {
            let frameData = Data(bytesNoCopy: dataPtr, count: Int(length), deallocator: .none)
            return createAV1FormatDescriptionForIDRFrame(frameData)
        } else {
            abort()
        }
    }

    /// Hands the collected parameter sets to the caller and clears them, so the next IDR
    /// starts from an empty list.
    private func takeParameterSets() -> [NSData] {
        let parameterSets = parameterSetBuffers
        parameterSetBuffers.removeAll()
        return parameterSets
    }

    private func createH264FormatDescription() -> CMVideoFormatDescription? {
        let parameterSets = takeParameterSets()
        let paramPtrs = parameterSets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let paramSizes = parameterSets.map(\.length)

        var fromatDesc: CMFormatDescription?
        let status = withExtendedLifetime(parameterSets) {
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: paramPtrs,
                parameterSetSizes: paramSizes,
                nalUnitHeaderLength: Int32(NAL_LENGTH_PREFIX_SIZE),
                formatDescriptionOut: &fromatDesc
            )
        }

        if status != noErr {
            print("Failed to create H264 format description: \(status)")
            return nil
        }
        guard let baseDesc = fromatDesc else { return nil }
        return enrichFormatDescription(baseDesc, codecType: kCMVideoCodecType_H264, codec: .h264)
    }

    private func createHEVCFormatDescription() -> CMVideoFormatDescription? {
        let parameterSets = takeParameterSets()
        let paramPtrs = parameterSets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let paramSizes = parameterSets.map(\.length)

        let videoFormatParams = NSMutableDictionary()

        if let contentLightLevelInfo = contentLightLevelInfo {
            videoFormatParams.setObject(contentLightLevelInfo, forKey: kCMFormatDescriptionExtension_ContentLightLevelInfo as NSString)
        }
        if let masteringDisplayColorVolume = masteringDisplayColorVolume {
            videoFormatParams.setObject(masteringDisplayColorVolume, forKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume as NSString)
        }

        var formatDesc: CMFormatDescription?
        let status = withExtendedLifetime(parameterSets) {
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: paramPtrs,
                parameterSetSizes: paramSizes,
                nalUnitHeaderLength: Int32(NAL_LENGTH_PREFIX_SIZE),
                extensions: videoFormatParams as CFDictionary,
                formatDescriptionOut: &formatDesc
            )
        }

        if status != noErr {
            print("Failed to create HEVC format description: \(status)")
            return nil
        }
        guard let baseDesc = formatDesc else { return nil }
        return enrichFormatDescription(baseDesc, codecType: kCMVideoCodecType_HEVC, codec: .hevc)
    }

    private enum CodecKind {
        case h264
        case hevc
        case av1
    }

    private func makeDefaultColorExtensions(for codec: CodecKind) -> NSMutableDictionary {
        let extensions = NSMutableDictionary()
        extensions[kCMFormatDescriptionExtension_FieldCount as NSString] = 1 as NSNumber

        switch codec {
        case .hevc where hdrEnabled || (videoFormat & VIDEO_FORMAT_H265_MAIN10) != 0:
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as NSString] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_TransferFunction as NSString] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix as NSString] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_FullRangeVideo as NSString] = false as NSNumber
            extensions[kCMFormatDescriptionExtension_Depth as NSString] = 30 as NSNumber
        default:
            // GameStream/Limelight SDR content is typically Rec.709 video-range.
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as NSString] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_TransferFunction as NSString] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix as NSString] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_FullRangeVideo as NSString] = false as NSNumber
            extensions[kCMFormatDescriptionExtension_Depth as NSString] = 24 as NSNumber
        }

        return extensions
    }

    private func enrichFormatDescription(
        _ baseDesc: CMVideoFormatDescription,
        codecType: CMVideoCodecType,
        codec: CodecKind
    ) -> CMVideoFormatDescription? {
        let mergedExtensions = ((CMFormatDescriptionGetExtensions(baseDesc) as NSDictionary?)?.mutableCopy() as? NSMutableDictionary) ?? NSMutableDictionary()
        let colorDefaults = makeDefaultColorExtensions(for: codec)
        // Keep stream-provided color metadata when available.
        // Only fill missing keys with safe defaults.
        colorDefaults.forEach { key, value in
            if mergedExtensions[key] == nil {
                mergedExtensions[key] = value
            }
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(baseDesc)
        var enrichedDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: dimensions.width,
            height: dimensions.height,
            extensions: mergedExtensions as CFDictionary,
            formatDescriptionOut: &enrichedDesc
        )

        if status != noErr {
            print("Failed to enrich format description: \(status)")
            return baseDesc
        }

        return enrichedDesc
    }

    private func codecDescription(_ format: Int32) -> String {
        if (format & VIDEO_FORMAT_MASK_AV1) != 0 {
            return (format & VIDEO_FORMAT_AV1_MAIN10) != 0 ? "AV1 Main10" : "AV1"
        }
        if (format & VIDEO_FORMAT_MASK_H265) != 0 {
            return (format & VIDEO_FORMAT_H265_MAIN10) != 0 ? "HEVC Main10" : "HEVC"
        }
        if (format & VIDEO_FORMAT_MASK_H264) != 0 {
            return "H264"
        }
        return "Unknown"
    }

    private func createAV1FormatDescriptionForIDRFrame(_ frameData: Data) -> CMVideoFormatDescription? {
        do {
            return try frameData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> CMVideoFormatDescription in
                var mutableBuffer = UnsafeMutableBufferPointer<UInt8>(mutating: buffer.bindMemory(to: UInt8.self))
                let fd = try CMVideoFormatDescriptionCreateFromAV1SequenceHeaderOBUWithAV1C(mutableBuffer)
                return fd as CMVideoFormatDescription
            }
        } catch {
            print("AV1 format description creation failed: \(error)")
            return nil
        }
    }

    // MARK: - Creating a Sample Buffer

    private func createSampleBuffer(
        dataPtr: UnsafeMutablePointer<UInt8>,
        length: Int,
        formatDesc: CMVideoFormatDescription,
        decodeUnit: PDECODE_UNIT!
    ) -> CMSampleBuffer? {
        var frameBlockBuffer: CMBlockBuffer?

        if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) != 0 {
            let nals = UnsafeMutableBufferPointer<UInt8>(start: UnsafeMutablePointer(mutating: dataPtr), count: length)
            frameBlockBuffer = annexBBufferToCMSampleBuffer(buffer: nals, videoFormat: formatDesc)
        } else {
            let statusDataBlock = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: dataPtr,
                blockLength: length,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: length,
                flags: 0,
                blockBufferOut: &frameBlockBuffer
            )
            if statusDataBlock != kCMBlockBufferNoErr {
                print("CMBlockBufferCreateWithMemoryBlock failed: \(statusDataBlock)")
                free(dataPtr)
                return nil
            }
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleTiming = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTimeMake(value: Int64(decodeUnit.pointee.presentationTimeMs), timescale: 1000),
            decodeTimeStamp: CMTime.invalid
        )
        let statusSample = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: frameBlockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        if statusSample != noErr {
            print("CMSampleBufferCreate failed: \(statusSample)")
            return nil
        }

        return sampleBuffer
    }

    private func findNaluIndices(bufferBounded: UnsafeMutableBufferPointer<UInt8>) -> ([NaluIndex], Bool) {
        var elgibleForModifyInPlace = true
        guard bufferBounded.count >= 3 else {
            return ([], false)
        }

        var sequences = [NaluIndex]()

        let end = bufferBounded.count - 3
        var i = 0
        let buffer = Data(bytesNoCopy: bufferBounded.baseAddress!, count: bufferBounded.count, deallocator: .none)
        while i < end {
            if buffer[i + 2] > 1 {
                i += 3
            } else if buffer[i + 2] == 1 {
                if buffer[i + 1] == 0 && buffer[i] == 0 {
                    var index = NaluIndex(startOffset: i, payloadStartOffset: i + 3, payloadSize: 0, threeByteHeader: true)
                    if index.startOffset > 0 && buffer[index.startOffset - 1] == 0 {
                        index.startOffset -= 1
                        index.threeByteHeader = false
                    } else {
                        elgibleForModifyInPlace = false
                    }

                    if !sequences.isEmpty {
                        sequences[sequences.count - 1].payloadSize = index.startOffset - sequences.last!.payloadStartOffset
                    }

                    sequences.append(index)
                }

                i += 3
            } else {
                i += 1
            }
        }

        if !sequences.isEmpty {
            sequences[sequences.count - 1].payloadSize = bufferBounded.count - sequences.last!.payloadStartOffset
        }

        return (sequences, elgibleForModifyInPlace)
    }

    private struct NaluIndex {
        var startOffset: Int
        var payloadStartOffset: Int
        var payloadSize: Int
        var threeByteHeader: Bool
    }

    private func annexBBufferToCMSampleBuffer(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat: CMFormatDescription) -> CMBlockBuffer? {
        let (naluIndices, elgibleForModifyInPlace) = findNaluIndices(bufferBounded: buffer)

        if elgibleForModifyInPlace {
            return annexBBufferToCMSampleBufferModifyInPlace(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        } else {
            return annexBBufferToCMSampleBufferWithCopy(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        }
    }

    private func annexBBufferToCMSampleBufferWithCopy(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat _: CMFormatDescription, naluIndices: [NaluIndex]) -> CMBlockBuffer? {
        var err: OSStatus = 0
        defer { buffer.deallocate() }

        let blockBufferLength = buffer.count + naluIndices.filter(\.threeByteHeader).count
        
        guard let blockBuffer = try? CMBlockBuffer(length: blockBufferLength, flags: .assureMemoryNow) else {
            print("Failed to allocate CMBlockBuffer (\(blockBufferLength) bytes) - dropping frame due to memory pressure")
            return nil
        }

        var contiguousBuffer: CMBlockBuffer!
        if !CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) {
            err = CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: blockBuffer, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguousBuffer)
            if err != 0 {
                print("CMBlockBufferCreateContiguous error")
                return nil
            }
        } else {
            contiguousBuffer = blockBuffer
        }

        var blockBufferSize = 0
        var dataPtr: UnsafeMutablePointer<Int8>!
        err = CMBlockBufferGetDataPointer(contiguousBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &blockBufferSize, dataPointerOut: &dataPtr)
        if err != 0 {
            print("CMBlockBufferGetDataPointer error")
            return nil
        }

        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(dataPtr))!
        var offset = 0

        buffer.withUnsafeBytes { unsafeBytes in
            let bytes = unsafeBytes.bindMemory(to: UInt8.self).baseAddress!

            for index in naluIndices {
                pointer.advanced(by: offset).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
                pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
                pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >> 8) & 0xFF)
                pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize) & 0xFF)
                offset += 4

                pointer.advanced(by: offset).update(from: bytes.advanced(by: index.payloadStartOffset), count: index.payloadSize)
                offset += index.payloadSize
            }
        }

        return contiguousBuffer
    }

    private func annexBBufferToCMSampleBufferModifyInPlace(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat _: CMFormatDescription, naluIndices: [NaluIndex]) -> CMBlockBuffer? {
        var offset = 0

        let umrbp = UnsafeMutableRawBufferPointer(start: buffer.baseAddress, count: buffer.count)
        
        guard let bb = try? CMBlockBuffer(buffer: umrbp, deallocator: { _, _ in buffer.deallocate() }, flags: .assureMemoryNow) else {
            print("Failed to create CMBlockBuffer from buffer (\(buffer.count) bytes) - dropping frame due to memory pressure")
            buffer.deallocate()
            return nil
        }

        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(buffer.baseAddress!))!
        for index in naluIndices {
            pointer.advanced(by: offset + 0).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
            pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
            pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >> 8) & 0xFF)
            pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize) & 0xFF)
            offset += 4

            offset += index.payloadSize
        }

        return bb
    }

    // MARK: - HDR Mode

    func setHdrMode(_ enabled: Bool) {
        let displayMetadata = HDRParsingUtils.parseHDRDisplayMetadata(enabled)
        let lightMetadata = HDRParsingUtils.parseHDRLightMetadata(enabled)

        decodeLock.lock()
        defer { decodeLock.unlock() }
        let metadataChanged = displayMetadata != masteringDisplayColorVolume
            || lightMetadata != contentLightLevelInfo
        masteringDisplayColorVolume = displayMetadata
        contentLightLevelInfo = lightMetadata

        if metadataChanged {
            LiRequestIdrFrame()
        }
    }

    private func buildCopyPipeline(fragment: String) -> MTLRenderPipelineState? {
        guard
            let library = mtlDevice.makeDefaultLibrary()
        else {
            return nil
        }
        
        let vertexFunction = library.makeFunction(name: "copyVertexShader")
        let fragmentFunction = library.makeFunction(name: fragment)
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "CopyBlitPipeline:\(fragment)"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        pipelineDescriptor.maxVertexAmplificationCount = 1

        return try? mtlDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
}

// MARK: - Pixel Format Traits

/// What the shaders need to know about a VT output pixel format. Classified once per format
/// change rather than on every frame.
private struct PixelFormatTraits {
    let pixelFormat: OSType
    /// 10-bit YUV from VT is almost always HDR (PQ/HLG) in this pipeline; 8-bit is SDR — do **not** key off `hdrEnabled`.
    let isTenBit: Bool
    /// nil when the pixel format doesn't encode the range; the format description decides then.
    let isFullRange: Bool?

    init(pixelFormat pf: OSType) {
        pixelFormat = pf

        switch pf {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat,
             kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange:
            isTenBit = true
        default:
            isTenBit = false
        }

        switch pf {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat,
             kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange:
            isFullRange = true
        default:
            isFullRange = nil
        }
    }
}

// MARK: - Constants Port

private let NAL_LENGTH_PREFIX_SIZE: Int = 4

let VIDEO_FORMAT_H264: Int32 = 0x0001
let VIDEO_FORMAT_H265: Int32 = 0x0100
let VIDEO_FORMAT_H265_MAIN10: Int32 = 0x0200
let VIDEO_FORMAT_AV1_MAIN8: Int32 = 0x1000
let VIDEO_FORMAT_AV1_MAIN10: Int32 = 0x2000

let VIDEO_FORMAT_MASK_H264: Int32 = 0x000F
let VIDEO_FORMAT_MASK_H265: Int32 = 0x0F00
let VIDEO_FORMAT_MASK_AV1: Int32 = 0xF000
let VIDEO_FORMAT_MASK_10BIT: Int32 = 0x2200

let FRAME_TYPE_IDR = 0x01
let BUFFER_TYPE_PICDATA = 0x00
let BUFFER_TYPE_VPS = 1
let BUFFER_TYPE_SPS = 2
let BUFFER_TYPE_PPS = 3

let DR_OK: Int32 = 0
let DR_NEED_IDR: Int32 = -1
