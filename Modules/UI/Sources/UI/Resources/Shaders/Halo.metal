#include <metal_stdlib>
using namespace metal;

// Mirror of the Swift `HaloVertex` (same field order; 32-byte stride: a float2
// position followed by a float4 colour, the float4 forcing 16-byte alignment).
struct HaloVertex {
    float2 position; // pixel space, top-left origin (y grows downward)
    float4 color;    // sRGB, alpha already pre-applied on the CPU
};

// Mirror of the Swift `HaloShapeInstance` (same field order; 48-byte stride).
// One instance is either a ripple ring or the centre glow; `kind` selects which
// SDF the fragment shader evaluates.
struct HaloShapeInstance {
    float2 center;    // pixel space
    float radius;     // outer radius in pixels
    float halfWidth;  // ring half-stroke-width in pixels (rings only)
    float4 color;     // sRGB, alpha already pre-applied on the CPU
    float kind;       // 0 = ring, 1 = gradient glow, 2 = flat glow disc
};

struct GeometryOut {
    float4 position [[position]];
    float4 color;
};

struct ShapeOut {
    float4 position [[position]];
    float2 pixelPos;  // interpolated, for the SDF
    float2 center;    // per-instance, constant across the quad
    float radius;
    float halfWidth;
    float kind;
    float4 color;
};

// Pixel (y down) to NDC (y up): the single y-flip for the whole pipeline.
static inline float2 pixelToNDC(float2 pixel, float2 drawableSize) {
    return float2(
        pixel.x / drawableSize.x * 2.0 - 1.0,
        1.0 - pixel.y / drawableSize.y * 2.0
    );
}

// Geometry pipeline: the membrane fan and the rim ribbon share it. Both feed
// pre-computed pixel-space positions with a per-vertex colour through buffer(0);
// the vertex shader only flips into NDC. The membrane fan passes its uniform
// fill colour as the per-vertex colour, so no separate "flat colour" path is
// needed.
vertex GeometryOut halo_geometry_vertex(
    uint vid [[vertex_id]],
    constant HaloVertex *vertices [[buffer(0)]],
    constant float2 &drawableSize [[buffer(1)]]
) {
    HaloVertex v = vertices[vid];
    GeometryOut out;
    out.position = float4(pixelToNDC(v.position, drawableSize), 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 halo_geometry_fragment(GeometryOut in [[stage_in]]) {
    // Alpha is pre-applied on the CPU; the fragment just passes the colour.
    return in.color;
}

// Shape pipeline: ripples and the centre glow share it. Each instance is one
// screen-space quad (six vertices pulled from vertex_id) sized to the shape's
// bounding box; the fragment evaluates the matching SDF.
vertex ShapeOut halo_shape_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant HaloShapeInstance *instances [[buffer(0)]],
    constant float2 &drawableSize [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    HaloShapeInstance inst = instances[iid];
    // Pad the bounding box by the half-width so the antialiased ring edge is not
    // clipped at the quad boundary.
    float pad = inst.halfWidth + 2.0;
    float2 rectMin = inst.center - float2(inst.radius + pad);
    float2 rectMax = inst.center + float2(inst.radius + pad);
    float2 unit = corners[vid % 6];
    float2 pixel = mix(rectMin, rectMax, unit);

    ShapeOut out;
    out.position = float4(pixelToNDC(pixel, drawableSize), 0.0, 1.0);
    out.pixelPos = pixel;
    out.center = inst.center;
    out.radius = inst.radius;
    out.halfWidth = inst.halfWidth;
    out.kind = inst.kind;
    out.color = inst.color;
    return out;
}

fragment float4 halo_shape_fragment(ShapeOut in [[stage_in]]) {
    float dist = length(in.pixelPos - in.center);

    if (in.kind < 0.5) {
        // Ring (annulus) SDF: distance to the stroke centreline minus the half
        // width, with one pixel of analytic antialiasing.
        float ring = abs(dist - in.radius) - in.halfWidth;
        float aa = max(fwidth(ring), 1e-4);
        float coverage = 1.0 - smoothstep(-aa, aa, ring);
        return float4(in.color.rgb, in.color.a * coverage);
    }

    if (in.kind < 1.5) {
        // Gradient glow: radial falloff from full alpha at the centre to clear at
        // the radius, matching the Canvas `radialGradient`.
        float t = 1.0 - smoothstep(0.0, in.radius, dist);
        return float4(in.color.rgb, in.color.a * t);
    }

    // Flat glow disc (reduce transparency): solid inside the radius, antialiased
    // at the rim.
    float edge = dist - in.radius;
    float aa = max(fwidth(edge), 1e-4);
    float coverage = 1.0 - smoothstep(-aa, aa, edge);
    return float4(in.color.rgb, in.color.a * coverage);
}
