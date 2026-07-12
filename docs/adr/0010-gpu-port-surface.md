# 0010. gpu port surface: Device / Texture / Buffer / Pipeline / CommandList

- Status: accepted
- Date: 2026-07-12

## Context

ADR 0006 built the Vulkan backend offscreen-first and deliberately left the `gpu`
**port surface** open: §3 said the engine-owned vocabulary (image/buffer/pipeline/
command-list) is "discovered across M1–M3 and pinned here as it solidifies, not
designed up front." M3 landed — the backend renders the ECS scene as iso-projected
quads to a PNG — so the vocabulary is now known from a *working* backend, which is
exactly when the abstraction policy permits pinning it (CLAUDE.md: "second concrete
impl planned, or don't abstract"; here the two impls are the null backend and
Vulkan).

Until this ADR the port was under-abstracted in one direction and over-exposed in
another:

- The whole render was **one 265-line `renderScene`** inside the Vulkan backend. It
  was the only GPU operation, but it inlined device bring-up, image/buffer/pipeline
  creation, command recording, submit, and readback with no shared vocabulary.
- The engine reached it as `engine.gpu.vk.renderScene` — naming the *Vulkan backend*
  by name. No Vulkan *type* leaked (the signature is plain data: dimensions, `Quad`s,
  clear colour → RGBA bytes), so invariant #4 held, but the backend identity leaked
  into the caller, and the **null backend had no render path at all** — it could not
  be the "real test double" CLAUDE.md requires because it implemented nothing.

The task: pin the minimal port surface the current renderer actually exercises, make
`renderScene` express itself through it, and have both backends implement the same
surface — the null backend as a real CPU adapter, the parity check for the port.

## Decision

### 1. The pinned vocabulary (what `gpu` owns)

The port is a small **device + resource + command** surface, described by plain-data
descriptors in `src/gpu/port.zig` (no backend types), implemented concretely by each
backend and re-exported from `gpu.zig`:

- **`Device`** — owns backend bring-up and teardown (`init`/`deinit`), creates
  resources, and submits recorded work. One device per render.
- **`Texture`** — an offscreen colour target. Created from a `TextureDesc`
  (`width`, `height`, `TextureFormat`, `TextureUsage{ color_attachment, transfer_src }`).
- **`Buffer`** — a host-visible byte buffer. Created from a `BufferDesc`
  (`size`, `BufferUsage{ vertex, transfer_dst }`); `write` uploads, `read` reads back.
- **`Pipeline`** — the scene graphics pipeline (`createScenePipeline(format)`).
- **`CommandList`** — records one submission: `beginRendering(target, clear)`,
  `bindPipeline`, `bindVertexBuffer`, `draw(vertex_count)`, `endRendering`,
  `copyTextureToBuffer(texture, buffer)`.
- **`Vertex`** — the one vertex layout the scene pipeline consumes (NDC position +
  RGB colour), shared by both backends and the vertex builder.

`TextureFormat` has exactly one member (`rgba8_unorm`); the usage flag sets carry
only the bits the two current resources need. This is the **whole** surface — nothing
speculative. No depth/stencil, no MSAA resolve, no bind groups / descriptors, no
multi-pass, no swapchain, no queue/sync primitives are exposed, because the renderer
does not use them. Widening the vocabulary is a later ADR justified by a concrete
renderer need (e.g. a sprite batcher, a depth buffer, or the SDL3 swapchain slice).

### 2. `renderScene` is backend-agnostic

`gpu.renderScene` moves **out** of the Vulkan backend and becomes the port's single
operation, written once against the vocabulary: create a `Texture`, a readback
`Buffer`, a `Pipeline`, and (when there are quads) a vertex `Buffer`; record a
`CommandList` (clear → draw → copy); submit; read back RGBA8 pixels. It names no
backend. The comptime-selected `Device` resolves the concrete types, so the same
driver compiles against both backends — and, because it is unguarded, the default
build **compiles it against the null backend** and the Vulkan build against Vulkan,
keeping the two surfaces in lockstep (a signature drift is a build error).

The vertex expansion (quad → two triangles) also moves into the shared driver, so
both backends consume identical geometry through the shared `Vertex` layout.

### 3. The null backend is a real adapter (the test double)

`src/gpu/null/backend.zig` implements the same surface entirely on the CPU: a
`Texture` is a host pixel buffer, a `Buffer` is host bytes, and the `CommandList` is
immediate-mode — `beginRendering` clears, `draw` software-rasterizes the bound
vertices, `copyTextureToBuffer` memcpys back. It rasterizes **axis-aligned quads**
(the only geometry the scene pipeline emits — two triangles per quad); it is
deliberately not a general triangle rasterizer, matching "the test double draws what
the port draws." This makes the null backend the parity check CLAUDE.md asks for: its
in-file test drives the full `Device` surface and asserts real pixels, in every
headless/CI build, GPU-free.

### 4. Boundary unchanged; invariant preserved

Vulkan types stay inside `src/gpu/vulkan/**`. The backend module is now **internal**
to `gpu` (no `pub const vk`): callers use the port types and `renderScene`, so the
backend is no longer named above `gpu`. Verified: no `@import("vulkan")` and no `vk.`
type appears anywhere under `src/` outside `src/gpu/`. The Vulkan backend still
compiles only under `-Denable-vulkan`; the null backend is the default.

### 5. Not decided here

Memory-placement choice on `Buffer`/`Texture` (all current buffers are host-visible,
the target device-local — no resource needs a choice), a resource-handle/lifetime
scheme beyond value structs with `deinit(dev)`, and any async/multi-frame submission.
Each waits for a milestone that needs it.

## Consequences

- **Easier:** the engine sees one stable, plain-data port; the null backend is a real
  renderer and a byte-checkable parity harness; a future backend implements one small
  surface; `renderScene` is written once, not per backend.
- **Harder / accepted:** two backends must keep method signatures identical (enforced
  by the shared driver compiling against both); the null rasterizer is quad-only by
  design and grows only with the port.
- **Committed to:** the vocabulary in §1 as the pinned `gpu` surface. Additions go
  through a new ADR. Verified behavior-preserving: the `-Denable-vulkan` scene render
  produces a **byte-identical** PNG to the pre-refactor backend.
