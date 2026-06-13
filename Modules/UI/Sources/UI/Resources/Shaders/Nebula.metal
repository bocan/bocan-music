#include <metal_stdlib>
using namespace metal;

// Mirror of the Swift `NebulaUniforms` (same field order, 96 bytes). Every
// audio-reactive number arrives here from the CPU; this shader does no audio
// math, it only consumes uniforms (testability contract).
struct NebulaUniforms {
    float2 drawableSize; // pixels; aspect ratio derives from this, not the view
    float flowTime;      // CPU-integrated flow clock (gas churn + wisp orbits)
    float warpAmp;       // domain-warp amplitude, mid-energy modulated
    float exposure;      // brightness multiplier, onset-boosted
    float onsetPulse;    // onset pressure-wave envelope, 0...1
    float centroidTint;  // LUT hue offset from the spectral centroid
    float loudestWisp;   // index 0...3 of the pressure-wave centre wisp
    float2 wisp0;        // wisp centres in aspect-corrected UV
    float2 wisp1;
    float2 wisp2;
    float2 wisp3;
    float4 wispStrengths; // four band-group energies
    float4 wispRadii;     // four blob radii
};

struct VertexOut {
    float4 position [[position]];
    float2 uv; // 0...1 across the drawable, y down
};

// Fullscreen triangle from vertex_id, no vertex buffer (matches Cascade).
vertex VertexOut nebula_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2); // (0,0), (2,0), (0,2)
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, p.y);
    return out;
}

// 2D value-noise hash, deterministic and cheap. Standard fract-of-dot-product.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

// Bilinear-interpolated value noise on the integer lattice, smoothstep-faded.
static float value_noise(float2 p) {
    float2 cell = floor(p);
    float2 frac = fract(p);
    float2 weight = frac * frac * (3.0 - 2.0 * frac);
    float a = hash21(cell + float2(0.0, 0.0));
    float b = hash21(cell + float2(1.0, 0.0));
    float c = hash21(cell + float2(0.0, 1.0));
    float d = hash21(cell + float2(1.0, 1.0));
    return mix(mix(a, b, weight.x), mix(c, d, weight.x), weight.y);
}

// 4-octave fractional Brownian motion: the gas texture.
static float fbm(float2 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    float2 sample = p;
    for (int octave = 0; octave < 4; octave++) {
        sum += amplitude * value_noise(sample);
        sample *= 2.0;
        amplitude *= 0.5;
    }
    return sum;
}

// Rotate `p` around `centre` by `angle`.
static float2 rotate_around(float2 p, float2 centre, float angle) {
    float2 d = p - centre;
    float cosA = cos(angle);
    float sinA = sin(angle);
    return centre + float2(d.x * cosA - d.y * sinA, d.x * sinA + d.y * cosA);
}

fragment float4 nebula_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> palette [[texture(0)]],
    sampler paletteSampler [[sampler(0)]],
    constant NebulaUniforms &u [[buffer(0)]]
) {
    // Aspect-corrected UV centred at the origin, derived from the drawable size
    // uniform so the gas keeps its shape at any render scale. y up (flip the
    // top-down vertex uv) so the field matches the CPU-side wisp coordinates.
    float aspect = u.drawableSize.x / max(u.drawableSize.y, 1.0);
    float2 uv = float2((in.uv.x - 0.5) * 2.0 * aspect, (0.5 - in.uv.y) * 2.0);

    float2 wisps[4] = { u.wisp0, u.wisp1, u.wisp2, u.wisp3 };
    float strengths[4] = {
        u.wispStrengths.x, u.wispStrengths.y, u.wispStrengths.z, u.wispStrengths.w
    };
    float radii[4] = { u.wispRadii.x, u.wispRadii.y, u.wispRadii.z, u.wispRadii.w };

    // Onset pressure wave: a radial displacement pulse centred on the loudest
    // wisp, pushing the sample point outward as the wave passes through the gas.
    int loudest = clamp(int(u.loudestWisp + 0.5), 0, 3);
    float2 pulseCentre = wisps[loudest];
    float2 toPixel = uv - pulseCentre;
    float distToCentre = length(toPixel);
    float ring = sin(distToCentre * 9.0 - u.flowTime * 3.0);
    float waveFalloff = exp(-distToCentre * 1.4);
    float2 pulseDir = toPixel / max(distToCentre, 1e-4);
    float2 warped = uv + pulseDir * (ring * waveFalloff * u.onsetPulse * 0.18);

    // Local swirl: each wisp rotates the warp domain around itself, falling off
    // with distance, so the gas visibly spirals around the bright shapes.
    float2 swirled = warped;
    for (int index = 0; index < 4; index++) {
        float dist = length(warped - wisps[index]);
        float influence = exp(-dist * 3.5) * strengths[index];
        swirled = rotate_around(swirled, wisps[index], influence * 2.2);
    }

    // Classic IQ domain warping: three nested fBm evaluations. dir1/dir2 give the
    // two layers independent drift directions; warpAmp knots the clouds.
    float2 base = swirled * 1.8;
    float2 dir1 = float2(0.12, 0.21);
    float2 dir2 = float2(-0.17, 0.09);
    float2 q = float2(
        fbm(base + dir1 * u.flowTime),
        fbm(base + dir1 * u.flowTime + 5.2)
    );
    float2 r = float2(
        fbm(base + u.warpAmp * q + dir2 * u.flowTime),
        fbm(base + u.warpAmp * q + dir2 * u.flowTime + 3.1)
    );
    float density = fbm(base + u.warpAmp * r);

    // Add each wisp's Gaussian density blob, brightening the gas where the bright
    // shapes sit. Strength fades the blob out for a silent group.
    for (int index = 0; index < 4; index++) {
        float dist = length(uv - wisps[index]);
        float sigma = max(radii[index], 1e-3);
        float blob = exp(-(dist * dist) / (sigma * sigma));
        density += blob * strengths[index] * 0.6;
    }
    density = clamp(density, 0.0, 1.0);

    // Map density through the palette LUT, offset by the centroid tint, then apply
    // the onset-boosted exposure. Composited opaque over black in-shader so the
    // output never depends on layer blending (satisfies reduce transparency).
    float lutCoord = clamp(density + u.centroidTint, 0.0, 1.0);
    float4 colour = palette.sample(paletteSampler, float2(lutCoord, 0.5));
    // Fold the (non-audio) density into a brightness term so the gas keeps its
    // structure even under flat-RGB palettes (mono, accent) whose LUT carries no
    // luminance ramp of its own. Palettes that already darken at low density
    // (thermal, spectrum) only deepen their shadows slightly. This is purely a
    // density-to-luminance shaping; no audio value participates.
    float luminance = mix(0.18, 1.0, density * density);
    float3 lit = clamp(colour.rgb * luminance * u.exposure, 0.0, 1.0);
    return float4(lit, 1.0);
}
