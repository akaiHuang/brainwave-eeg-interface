//
//  Shaders.metal
//  Aura
//
//  Created by GitHub Copilot on 2025-01-18.
//  Purpose: Metal shaders for high-performance waveform rendering
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 數據結構

/// 頂點數據
struct Vertex {
    float2 position [[attribute(0)]];
};

/// 統一變數（從 CPU 傳遞到 GPU 的常量）
struct Uniforms {
    float4 color;      // 波形顏色 (RGBA)
    float lineWidth;   // 線條寬度
};

/// 從 vertex shader 傳遞到 fragment shader 的數據
struct RasterizerData {
    float4 position [[position]]; // 裁剪空間座標
    float4 color;                 // 顏色
};

// MARK: - Vertex Shader

/// 頂點著色器 - 將頂點從模型空間轉換到裁剪空間
vertex RasterizerData vertex_waveform(
    uint vertexID [[vertex_id]],
    constant float2 *vertices [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    RasterizerData out;
    
    // 直接使用已歸一化的座標（-1 到 1）
    float2 position = vertices[vertexID];
    
    // 轉換到裁剪空間（Metal 使用左手座標系，y 向上）
    out.position = float4(position, 0.0, 1.0);
    
    // 傳遞顏色到 fragment shader
    out.color = uniforms.color;
    
    return out;
}

// MARK: - Fragment Shader

/// 片段著色器 - 為每個像素計算最終顏色
fragment float4 fragment_waveform(
    RasterizerData in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    // 直接返回頂點顏色（已經包含 alpha）
    return in.color;
}

// MARK: - 抗鋸齒版本（可選，效能稍低但視覺更好）

/// 抗鋸齒 fragment shader - 使用距離場實現平滑邊緣
fragment float4 fragment_waveform_antialiased(
    RasterizerData in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]],
    float2 pointCoord [[point_coord]]
) {
    // 計算距離線條中心的距離
    float dist = abs(pointCoord.y - 0.5) * 2.0; // 0 到 1
    
    // 使用 smoothstep 實現抗鋸齒
    float alpha = 1.0 - smoothstep(0.0, 1.0, dist);
    
    // 應用到顏色的 alpha 通道
    float4 color = in.color;
    color.a *= alpha;
    
    return color;
}

// MARK: - 漸變色版本（用於多頻帶顯示）

/// 漸變色頂點數據
struct GradientVertex {
    float2 position [[attribute(0)]];
    float4 color [[attribute(1)]];
};

/// 漸變色 vertex shader
vertex RasterizerData vertex_waveform_gradient(
    uint vertexID [[vertex_id]],
    constant float2 *positions [[buffer(0)]],
    constant float4 *colors [[buffer(1)]],
    constant Uniforms &uniforms [[buffer(2)]]
) {
    RasterizerData out;
    
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.color = colors[vertexID];
    
    return out;
}

/// 漸變色 fragment shader
fragment float4 fragment_waveform_gradient(
    RasterizerData in [[stage_in]]
) {
    return in.color; // 顏色已在頂點之間插值
}

// MARK: - 效能優化版本（最小開銷）

/// 極簡 vertex shader - 無額外計算
vertex RasterizerData vertex_waveform_fast(
    uint vertexID [[vertex_id]],
    constant packed_float2 *vertices [[buffer(0)]], // 使用 packed 節省記憶體
    constant packed_float4 &color [[buffer(1)]]
) {
    RasterizerData out;
    out.position = float4(float2(vertices[vertexID]), 0.0, 1.0);
    out.color = float4(color);
    return out;
}

/// 極簡 fragment shader - 直接輸出
fragment float4 fragment_waveform_fast(
    RasterizerData in [[stage_in]]
) {
    return in.color;
}
