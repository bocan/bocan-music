#include <metal_stdlib>
using namespace metal;

// Mirror of the Swift `CascadeUniforms` (same field order, 48 bytes).
struct CascadeUniforms {
    float4 nowColor;
    float cursorPlusOffset; // ring cursor + sub-column scroll offset, in columns
    float nowLineWidthUV;   // now-line width as a fraction of screen width
    float glowAlpha;        // white now-line glow, 0 when expired or reduce motion
    float showNowLine;      // 1 = draw the now line + glow, 0 = reduce motion
    float4 pad;             // explicit padding to 48 bytes
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle from vertex_id, no vertex buffer. uv.x runs 0 (left) to 1
// (right); uv.y runs 0 (top) to 1 (bottom) so texture row 0 (treble) is at the
// top, matching the history texture's memory layout.
vertex VertexOut cascade_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2); // (0,0), (2,0), (0,2)
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 cascade_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> history [[texture(0)]],
    sampler historySampler [[sampler(0)]],
    constant CascadeUniforms &u [[buffer(0)]]
) {
    // Screen-left samples the oldest column (the ring cursor), screen-right the
    // newest (cursor - 1). The .repeat address mode wraps the ring; the
    // sub-column offset slides everything left between column writes.
    float texU = (in.uv.x * 256.0 + u.cursorPlusOffset) / 256.0;
    float4 color = history.sample(historySampler, float2(texU, in.uv.y));

    if (u.showNowLine > 0.5 && in.uv.x > 1.0 - u.nowLineWidthUV) {
        color = mix(color, u.nowColor, u.nowColor.a);
        color = mix(color, float4(1.0, 1.0, 1.0, 1.0), u.glowAlpha);
    }
    return color;
}
