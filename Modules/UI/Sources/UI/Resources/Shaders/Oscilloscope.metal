#include <metal_stdlib>
using namespace metal;

// Mirror of the Swift `OscilloscopeUniforms` (same field order, 32 bytes).
struct OscilloscopeUniforms {
    float4 traceColor;
    float4 lineColor;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

// Vertex pulling: positions are pre-computed NDC float2s in buffer(0). The
// colorSelector (buffer(2)) picks the trace colour (0) or the centre-line
// colour (1) so both strips share one pipeline and one draw shader.
vertex VertexOut oscilloscope_vertex(
    uint vid [[vertex_id]],
    constant float2 *positions [[buffer(0)]],
    constant OscilloscopeUniforms &uniforms [[buffer(1)]],
    constant uint &colorSelector [[buffer(2)]]
) {
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.color = (colorSelector == 0u) ? uniforms.traceColor : uniforms.lineColor;
    return out;
}

fragment float4 oscilloscope_fragment(VertexOut in [[stage_in]]) {
    return in.color;
}
