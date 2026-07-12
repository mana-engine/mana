// Triangle shader (ADR 0006 M2). Authored in WGSL; compiled to SPIR-V by `naga`
// into triangle.spv, which the backend @embedFiles. Regenerate with:
//   naga src/gpu/vulkan/shaders/triangle.wgsl src/gpu/vulkan/shaders/triangle.spv
// The three vertices are generated from the vertex index (no vertex buffer).

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec3<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(0.0, -0.6),
        vec2<f32>(0.6, 0.6),
        vec2<f32>(-0.6, 0.6),
    );
    var colors = array<vec3<f32>, 3>(
        vec3<f32>(0.90, 0.30, 0.35),
        vec3<f32>(0.30, 0.85, 0.45),
        vec3<f32>(0.35, 0.55, 0.95),
    );
    var out: VsOut;
    out.pos = vec4<f32>(positions[vi], 0.0, 1.0);
    out.color = colors[vi];
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.color, 1.0);
}
