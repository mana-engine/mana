// Sprite shader (ADR 0031 §4; issue #113 phase 2b). Draws textured, tinted quads that
// sample a sprite atlas. Positions arrive already in NDC (the engine projects entity
// transforms on the CPU, rotating a directional quad to face its travel direction);
// UVs address the current frame's sub-rect of the atlas. The atlas is a separate
// texture + sampler (naga emits `texture_2d` and `sampler` as two distinct bindings,
// matching the backend's descriptor-set layout). Compile with: mise run shaders.

struct VsIn {
    @location(0) pos: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) tint: vec3<f32>,
};

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) tint: vec3<f32>,
};

@vertex
fn vs_main(in: VsIn) -> VsOut {
    var out: VsOut;
    out.pos = vec4<f32>(in.pos, 0.0, 1.0);
    out.uv = in.uv;
    out.tint = in.tint;
    return out;
}

@group(0) @binding(0) var atlas_tex: texture_2d<f32>;
@group(0) @binding(1) var atlas_sampler: sampler;

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    // Straight-alpha texel (ADR 0031 §2). Tint multiplies RGB only (white = untinted);
    // alpha passes through so the pipeline's src-alpha-over blend composites the sprite.
    let texel = textureSample(atlas_tex, atlas_sampler, in.uv);
    return vec4<f32>(texel.rgb * in.tint, texel.a);
}
