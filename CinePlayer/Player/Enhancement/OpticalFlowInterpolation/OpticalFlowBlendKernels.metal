//
//  OpticalFlowBlendKernels.metal
//  Cinemore
//
//  单 Pass 双向光流补帧：
//  - 支持下采样光流纹理，按 outSize / flowSize 自动缩放位移向量与一致性残差；
//  - 对 prev/next 各自做 backward-warp，再结合颜色一致性 + 前后向一致性双重置信度合成；
//  - 低置信度区域平滑回退到未 warp 原帧的线性混合，避免大位移/遮挡鬼影与果冻抖动。
//

#include <metal_stdlib>
using namespace metal;

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

struct OpticalFlowFusedParams {
    float t;
    float flowErrorPivot;
};

kernel void opticalFlowInterpolateFused(
    texture2d<float, access::sample> prevTexture   [[texture(0)]],
    texture2d<float, access::sample> nextTexture   [[texture(1)]],
    texture2d<float, access::sample> flowForward   [[texture(2)]],
    texture2d<float, access::sample> flowBackward  [[texture(3)]],
    texture2d<float, access::write>  outputTexture [[texture(4)]],
    constant OpticalFlowFusedParams &params        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float2 outSize = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 flowSize = max(float2(flowForward.get_width(), flowForward.get_height()), float2(1.0));
    float2 flowToOut = outSize / flowSize;
    float2 uv = (float2(gid) + 0.5) / outSize;

    // 1) 采样下采样坐标系下的前后向光流，并换算到输出像素空间
    float2 fwdFlow = flowForward.sample(linearSampler, uv).xy;
    float2 bwdFlow = flowBackward.sample(linearSampler, uv).xy;
    float2 fwdOut = fwdFlow * flowToOut;
    float2 bwdOut = bwdFlow * flowToOut;

    // 2) 软门去噪：消除静态区 Vision 亚像素抖动
    float2 fwdSoft = fwdOut * smoothstep(0.1, 0.25, length(fwdOut));
    float2 bwdSoft = bwdOut * smoothstep(0.1, 0.25, length(bwdOut));

    // 3) 双向 backward-warp 与未 warp 原帧采样
    float2 prevUV = clamp(uv - (fwdSoft * params.t) / outSize, float2(0.0), float2(1.0));
    float2 nextUV = clamp(uv - (bwdSoft * (1.0 - params.t)) / outSize, float2(0.0), float2(1.0));
    float4 warpedPrev = prevTexture.sample(linearSampler, prevUV);
    float4 warpedNext = nextTexture.sample(linearSampler, nextUV);
    float4 unwarpedPrev = prevTexture.sample(linearSampler, uv);
    float4 unwarpedNext = nextTexture.sample(linearSampler, uv);

    // 4) 前后向光流一致性（用 flow 自身坐标系采样 bwdAtFwd，再放大回输出像素评估残差）
    float2 uvForward = clamp(uv + fwdFlow / flowSize, float2(0.0), float2(1.0));
    float2 bwdAtFwd = flowBackward.sample(linearSampler, uvForward).xy;
    float flowErr = length((fwdFlow + bwdAtFwd) * flowToOut);
    float flowConf = 1.0 - smoothstep(params.flowErrorPivot * 0.5, params.flowErrorPivot * 1.5, flowErr);

    // 5) 颜色一致性与双重置信度合成
    float colorErr = length(warpedPrev.rgb - warpedNext.rgb);
    float colorConf = 1.0 - smoothstep(0.08, 0.28, colorErr);
    float confidence = min(colorConf, flowConf);

    float4 warped = mix(warpedPrev, warpedNext, params.t);
    float4 unwarped = mix(unwarpedPrev, unwarpedNext, params.t);
    outputTexture.write(mix(unwarped, warped, confidence), gid);
}
