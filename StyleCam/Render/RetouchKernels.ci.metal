// Core Image 自定义滤镜：中性灰匀肤 / 祛痘 / 点修纹理
// 内置的“相乘”合成会把数值截到 0…1，没法把暗斑提亮，所以这里直接逐像素计算。
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" {
namespace coreimage {

/// img × (broad / fine)^k
/// broad：皮肤内大尺度平均；fine：去掉毛孔后的中尺度。比值偏离 1 的地方就是明暗起伏（痘印、暗沉）。
/// even 控制整体拉平程度；比周围明显暗的小斑点（比值亮度 > 1.04）按 blemish 进一步完全补平。
float4 scDodgeBurn(sample_t img, sample_t fine, sample_t broad, float even, float blemish) {
    float3 r = clamp((broad.rgb + 0.002) / (fine.rgb + 0.002), 0.6, 1.6);
    float lr = dot(r, float3(0.3, 0.59, 0.11));
    float spot = clamp((lr - 1.04) * 9.0, 0.0, 1.0) * clamp(blemish * 1.6, 0.0, 1.0);
    float k = mix(clamp(even, 0.0, 1.0) * 0.85, 1.0, spot);
    float3 o = img.rgb * pow(r, float3(k));
    return float4(o, img.a);
}

/// 点修：填充色 × 借来的细纹理（donor / donor 模糊，限制在 ±20%）
float4 scHealTexture(sample_t fill, sample_t donor, sample_t donorBlur) {
    float3 t = clamp((donor.rgb + 0.002) / (donorBlur.rgb + 0.002), 0.82, 1.2);
    return float4(fill.rgb * t, fill.a);
}

/// 位移变形（提拉）：输出 = 原图在 (当前位置 − 位移) 处的颜色；位移图的 R/G 是以像素计的 dx / dy
float4 scDisplace(sampler src, sampler disp, destination dest) {
    float2 p = dest.coord();
    float2 d = sample(disp, samplerTransform(disp, p)).xy;
    return sample(src, samplerTransform(src, p - d));
}

}
}
