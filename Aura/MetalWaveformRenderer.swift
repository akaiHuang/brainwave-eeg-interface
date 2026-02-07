//
//  MetalWaveformRenderer.swift
//  Aura
//
//  Created by GitHub Copilot on 2025-01-18.
//  Purpose: Metal-based high-performance waveform renderer
//  Power Target: 76% reduction in power consumption
//

import Metal
import MetalKit
import simd

/// Metal 波形渲染器 - 使用 Fragment Shader 實現高效能低功耗渲染
class MetalWaveformRenderer {
    
    // MARK: - Metal 核心元件
    
    /// Metal 設備（GPU）
    let device: MTLDevice  // was: private let device
    
    /// 命令佇列 - 用於提交 GPU 工作
    private let commandQueue: MTLCommandQueue
    
    /// 渲染管線狀態 - 包含編譯好的 shader
    private var pipelineState: MTLRenderPipelineState?
    
    /// 頂點緩衝區 - 存儲波形路徑頂點
    private var vertexBuffer: MTLBuffer?
    
    /// 統一變數緩衝區 - 存儲顏色、變換矩陣等
    private var uniformBuffer: MTLBuffer?
    
    // MARK: - 效能優化參數
    
    /// 當前目標幀率（可動態調整）
    private(set) var targetFPS: Int = 60
    
    /// 是否啟用低功耗模式
    private(set) var isLowPowerMode: Bool = false
    
    // MARK: - 初始化
    
    init?() {
        // 獲取 Metal 設備
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ Metal 不支援此設備")
            return nil
        }
        self.device = device
        
        // 建立命令佇列
        guard let commandQueue = device.makeCommandQueue() else {
            print("❌ 無法建立 Metal 命令佇列")
            return nil
        }
        self.commandQueue = commandQueue
        
        // 設定渲染管線
        setupPipeline()
        
        print("✅ Metal 渲染器初始化成功")
        print("   GPU: \(device.name)")
        print("   最大緩衝區長度: \(device.maxBufferLength / 1024 / 1024) MB")
    }
    
    // MARK: - 管線設定
    
    private func setupPipeline() {
        // 載入 shader library
        guard let library = device.makeDefaultLibrary() else {
            print("❌ 無法載入 Metal shader library")
            return
        }
        
        // 載入 vertex shader
        guard let vertexFunction = library.makeFunction(name: "vertex_waveform") else {
            print("❌ 無法載入 vertex_waveform shader")
            return
        }
        
        // 載入 fragment shader
        guard let fragmentFunction = library.makeFunction(name: "fragment_waveform") else {
            print("❌ 無法載入 fragment_waveform shader")
            return
        }
        
        // 建立管線描述符
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // 啟用混合模式（用於透明度）
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            print("✅ Metal 渲染管線建立成功")
        } catch {
            print("❌ 建立渲染管線失敗: \(error)")
        }
    }
    
    // MARK: - 渲染方法
    
    /// 渲染波形
    /// - Parameters:
    ///   - drawable: MTKView 的 drawable
    ///   - descriptor: 渲染通道描述符
    ///   - waveformData: 波形數據點 (歸一化到 -1.0 ~ 1.0)
    ///   - color: 波形顏色
    ///   - lineWidth: 線條寬度
    func render(
        drawable: CAMetalDrawable,
        descriptor: MTLRenderPassDescriptor,
        waveformData: [Float],
        color: simd_float4,
        lineWidth: Float = 2.0
    ) {
        guard let pipelineState = pipelineState else {
            print("⚠️ 渲染管線未就緒")
            return
        }
        
        // 更新頂點緩衝區
        updateVertexBuffer(with: waveformData)
        
        // 更新統一變數
        updateUniformBuffer(color: color, lineWidth: lineWidth)
        
        // 建立命令緩衝區
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("⚠️ 無法建立命令緩衝區")
            return
        }
        
        // 建立渲染編碼器
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            print("⚠️ 無法建立渲染編碼器")
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // 綁定頂點緩衝區
        if let vertexBuffer = vertexBuffer {
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        }
        
        // 綁定統一變數緩衝區
        if let uniformBuffer = uniformBuffer {
            renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        }
        
        // 繪製線條（使用 triangle strip 繪製帶寬度的線）
        let vertexCount = waveformData.count * 2 // 每個點拆成 2 個頂點
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)
        
        renderEncoder.endEncoding()
        
        // 提交到 GPU
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    // MARK: - 緩衝區更新
    
    private func updateVertexBuffer(with data: [Float]) {
        let vertexCount = data.count * 2 // 每個點拆成上下兩個頂點以形成帶寬度的線
        let bufferSize = vertexCount * MemoryLayout<simd_float2>.stride
        
        // 如果緩衝區不存在或大小不符，重新建立
        if vertexBuffer == nil || vertexBuffer!.length != bufferSize {
            vertexBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        }
        
        guard let vertexBuffer = vertexBuffer else { return }
        
        // 填充頂點數據
        let vertices = vertexBuffer.contents().bindMemory(to: simd_float2.self, capacity: vertexCount)
        
        for i in 0..<data.count {
            let x = Float(i) / Float(data.count - 1) * 2.0 - 1.0 // 歸一化到 -1 ~ 1
            let y = data[i] // 已經是 -1 ~ 1
            
            // 上頂點
            vertices[i * 2] = simd_float2(x, y + 0.01) // +0.01 產生線條寬度
            // 下頂點
            vertices[i * 2 + 1] = simd_float2(x, y - 0.01)
        }
    }
    
    private func updateUniformBuffer(color: simd_float4, lineWidth: Float) {
        struct Uniforms {
            var color: simd_float4
            var lineWidth: Float
        }
        
        let uniforms = Uniforms(color: color, lineWidth: lineWidth)
        let bufferSize = MemoryLayout<Uniforms>.stride
        
        // 如果緩衝區不存在，建立它
        if uniformBuffer == nil {
            uniformBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        }
        
        guard let uniformBuffer = uniformBuffer else { return }
        
        // 複製數據
        memcpy(uniformBuffer.contents(), [uniforms], bufferSize)
    }
    
    // MARK: - 效能控制（階段 2、3 使用）
    
    /// 設定目標幀率
    func setTargetFPS(_ fps: Int) {
        targetFPS = fps
        print("🎯 目標幀率設定為 \(fps) FPS")
    }
    
    /// 啟用/停用低功耗模式
    func setLowPowerMode(_ enabled: Bool) {
        isLowPowerMode = enabled
        if enabled {
            targetFPS = 30 // 低功耗模式降到 30 FPS
            print("🔋 低功耗模式已啟用 (30 FPS)")
        } else {
            targetFPS = 60
            print("⚡️ 標準模式已啟用 (60 FPS)")
        }
    }
    
    /// 設定背景模式（階段 3 使用）
    func setBackgroundMode(_ enabled: Bool) {
        if enabled {
            targetFPS = 1
            print("🌙 背景模式已啟用 (1 FPS)")
        } else {
            targetFPS = isLowPowerMode ? 30 : 60
            print("☀️ 前景模式已恢復")
        }
    }
}

// MARK: - 工具擴展

extension MetalWaveformRenderer {
    
    /// 將 CGColor 轉換為 simd_float4
    static func colorToFloat4(_ color: CGColor) -> simd_float4 {
        guard let components = color.components, components.count >= 3 else {
            return simd_float4(1, 1, 1, 1) // 預設白色
        }
        
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        let a = components.count >= 4 ? Float(components[3]) : 1.0
        
        return simd_float4(r, g, b, a)
    }
}
