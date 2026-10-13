# Sky and Volumetric Cloud System: Project Plan

Handoff document for continuing this work in Claude Code. It records the goal, decisions, current state, remaining phases and the gotchas found so far.

**Engine:** s&box. **Language:** C# component plus an HLSL post-process shader.
**Last updated:** 2026-10-13 (end of Phase 5 Step B).

---

## 1. Goal

A comprehensive atmosphere and cloud system for an s&box game:

- Multiple volumetric cloud layers with proper lighting (sun direction aware)
- Weather presets that blend over time
- Cloud shadows cast on the ground
- An analytic sky with sun, moon, stars and a day/night cycle
- Performance tiers so it runs on a range of hardware
- **Requirement:** clouds must look good from any angle. The camera can be below, inside or above any layer.
- **Eventual goal (deferred):** wrap everything around a real-scale planet with altitude-dependent atmosphere.

### Scope decision (important)

A spherical real-scale planet was considered first, then **deliberately deferred**. The current system uses **flat horizontal slabs** in a flat world (Z up). The atmosphere math assumes a virtual spherical planet *below* the flat world, which gives correct sky and horizon without any world-representation problems. Planet support is Phase 9 and should not require rewrites of the noise, lighting, layering or temporal code.

---

## 2. Environment and API notes (read first)

The assistant cannot run the engine; the user builds and reports back (the assistant can read `T:/SteamLibrary/steamapps/common/sbox/logs/sbox-dev.log` and the API XML docs in `bin/managed/*.xml`). Spots that depend on unverified s&box APIs are marked `API CHECK` in the code.

### s&box API whitelist
s&box compiles user code with a **whitelist**. `System.Threading.Tasks.Parallel` is **blocked**. Use `Sandbox.Utility.Parallel.For( int, int, Action<int> )` instead. If new code fails with `SB1000`, check the whitelist docs:
`https://github.com/Facepunch/sbox-docs/blob/master/docs/code/code-basics/api-whitelist.md`

### Confirmed API facts
- 3D textures: `Texture.CreateVolume( w, h, d, ImageFormat ).WithName(...).WithData( byte[], int ).Finish()`
- 2D textures: `Texture.Create( w, h, ImageFormat )...` (the `WithData` signature is assumed to match; not confirmed)
- `Attributes.Set( "name", value )` works for float, Vector3 and Vector4. Texture binding via the same call is assumed.
- Post process component: `BasePostProcess<T>`, drawn with `Blit( BlitMode.WithBackbuffer( material, Stage.AfterPostProcess, 200, false ), "name" )`.
- `Scene.Camera.ZFar` compiled and worked.
- Confirmed by the working system (2026-10-13): `ImageFormat.RGBA8888`; 2D `Texture.Create(...).WithData(...)`; `Attributes.Set( name, Texture )` for 2D and 3D; the `SamplerState` attribute syntax; `Depth::GetWorldPosition` on sky pixels; `DirectionalLight.LightColor`, `AmbientLight.Color`, `Rotation.LookAt( Vector3 )`; `[Group]`; `GpuBuffer<T>` bound with `Attributes.Set` as a `StructuredBuffer<T>` in a post-process blit.

### Still unverified (`API CHECK` markers)
| Item | Where |
|---|---|
| Whether `Stage.AfterPostProcess` runs before or after engine tone mapping | affects all exposure tuning |
| `Sandbox.Utility.Parallel.For` return value meaning (ignored by the baker) | `CloudBenchmark.cs` | Phase 5 measurement: pins the camera, freezes time and wind, runs Off/Low/Medium/High/Ultra and logs GPU frame time per tier (cloud cost = tier minus Off). |
| `CloudNoiseBaker.cs` |
| `PerformanceStats.GpuFrametime` / `GpuFrameNumber` (static), `Screen.Size` | `CloudBenchmark.cs` |

### Units
- s&box world units are **inches**; 1 unit = 0.0254 m.
- Cloud math in the shader: **meters**. Atmosphere math in the shader: **kilometers**. All conversion happens in C#.
- World **Z is up**. Layer altitudes are meters above `GroundLevel` (in world units, converted).

---

## 3. Architecture

### Files

| File | Role |
|---|---|
| `SkyCloudSystem.cs` | Component (`BasePostProcess<SkyCloudSystem>`). Owns settings, quality tiers, time of day and sun driving, CPU atmosphere (sun tint), ambient colors, scene light sync, wind accumulation, noise baking lifecycle, and all shader attributes. Also contains `CloudLayerSettings`, `CloudQuality`, `CloudDebugView`, `AtmosphereCpu`. |
| `CloudBenchmark.cs` | Phase 5 measurement: pins the camera, freezes time and wind, runs Off/Low/Medium/High/Ultra and logs GPU frame time per tier (cloud cost = tier minus Off). |
| `CloudNoiseBaker.cs` | CPU baker for tileable noise: shape 3D (RGBA8: R Perlin-Worley, GBA Worley fBm), detail 3D (RGB Worley fBm), weather 2D (R coverage, G regional cloud height: where towers cluster). Uses `Sandbox.Utility.Parallel.For`. |
| `sky_clouds.shader` | Full-screen post-process: sky (atmosphere, sun/moon/stars, below-horizon), aerial perspective on geometry, and the composite. Clouds come from `CloudTex` (bilinear upsample) or, with `Resolution = Full`, from `MarchClouds` per pixel. |
| `cloud_common.hlsl` | Shared by the blit and the trace compute pass: all attributes, constants, `CloudRay`/`MakeCloudRay`, atmosphere functions, cloud lighting, `CloudLayerIntervals` (debug) and `MarchClouds` (returns premultiplied cloud colour + transmittance). |
| `cloud_trace_cs.shader` | Phase 5 compute pass: `MarchClouds` per low-res texel into `CloudTex` (RGBA16F). |
| `cloud_density.hlsl` | Included inside the shader's `PS` block. Declares noise textures, sampler, the `CloudLayer` struct and the `CloudLayers` buffer. Provides `CloudTypeProfile`, `BaseCloudDensity` (per-cloud top + type profile + anvil), `SampleDensityLight` (no detail), `SampleDensity` (full). |

### Core design decisions

- **Baked noise only** (shape, detail, weather). Runtime Perlin was the original biggest cost.
- **Slab clouds:** horizontal slabs `[bottom, top]` in meters above ground. Ray-slab intersection handles camera below, inside and above, plus near-horizontal rays (no divide by ~0).
- **Up to 8 volumetric layers** in one `StructuredBuffer<CloudLayer>` (`CloudLayers`, C# `GpuBuffer<CloudLayerGpu>`) plus `layer_count`. C# uploads only enabled layers, **sorted by altitude**, and skips any layer that overlaps the one below (warning). The shader walks layers upward for rising rays and downward for falling rays, which is entry order for disjoint slabs (no per-pixel sort). One shared transmittance, front to back.
- `CloudLayer` = four float4s (64 bytes; C# struct must match):
  - `range`: x bottom (m), y top (m), z coverage, w density
  - `prm`: x shape freq (1/m), y/z wind offset (m), w detail strength
  - `nz`: x detail freq (1/m), y weather freq (1/m), z weather influence, w reserved
  - `shape`: x cloud type (0 stratus, 0.5 cumulus, 1 cumulonimbus), y height variation, z anvil, w reserved
- **Vertical structure:** bases sit on the layer bottom; each cloud has its own top = `lerp(1, lerp(0.12, 1, tall^2), HeightVariation)` of the layer height, where `tall` mixes a per-cloud signal (shape texture G channel on a fixed 2D slice, ~one Worley cell per cloud), the weather map G (regional) and coverage. The type profile and anvil are evaluated in the cloud's own normalized height, which also drives ambient and detail. For towers use one tall convective layer (e.g. 1.2 to 6.5 km) rather than overlapping layers.
- **Wind** is accumulated on the C# side as an XY offset (no wrapping, because the three textures tile at different periods).
- **Sky pixels:** a pixel is sky if reconstructed distance >= 99% of camera far clip. Clouds then march out to `MaxCloudDistanceKm`; the sky is rendered only for these pixels.
- **Atmosphere:** single-scatter march (Rayleigh, Mie g=0.76, ozone) on a virtual 6371 km planet, camera at `(0, 0, R + altitude)`. Cancellation-safe sphere intersection. A CPU copy (`AtmosphereCpu`) computes sun transmittance at camera altitude so cloud light, scene light and sky agree.
- **Tone mapping:** the shader tone-maps the sky and clouds itself (`1 - exp(-x * exposure)`), and leaves scene color alone. Separate `SkyExposure` and `CloudExposure`.
- **Aerial perspective** applies to geometry (distance > 100 m) and to clouds (at their transmittance-weighted mean distance).
- **Jitter:** interleaved gradient noise per pixel for now (to be replaced by blue noise plus frame index in Phase 5).
- **Quality tiers** (`CloudQuality`): view steps / light steps / sky steps / shape size / detail size
  - Low: 16 / 3 / 8 / 64³ / 16³
  - Medium: 32 / 4 / 12 / 64³ / 16³
  - High: 64 / 6 / 16 / 128³ / 32³
  - Ultra: 96 / 8 / 24 / 128³ / 32³

### Cloud lighting model (Phase 4)
- Light march toward the sun with growing step size (3 to 8 samples, cheap density without detail), step length scaled by thickness and stretched at low sun elevation.
- Beer-Lambert extinction.
- Multi-scatter approximation: 3 octaves (attenuation, contribution and phase eccentricity each halved per octave).
- Dual-lobe Henyey-Greenstein phase (own function `CloudHG`, not the engine's), normalized so isotropic = 1.
- Powder term for sun-facing edges, faded out when looking toward the sun.
- Ambient blends from a ground-lit bottom to a sky-colored top by normalized height.
- Direct sun color is the atmosphere-tinted color, so sunsets color the clouds automatically.

### Shader attribute contract (names must match C# and HLSL)
`sun_dir, sun_color, ambient_top, ambient_bottom, sun_disk_cos, moon_dir, moon_disk_cos, sky_enabled, sky_sun_intensity, sky_exposure, cloud_exposure, aerial_strength, ground_albedo, star_brightness, star_angle, horizon_fade, ground_z, max_cloud_distance, extinction, step_count, light_steps, sky_steps, debug_mode, CloudLayers, layer_count, ShapeNoise, DetailNoise, WeatherMap`; blit only: `CloudTex, cloud_lowres, SkyLut, SkyLutTrans, star_density, milky_way`; compute only: `CloudOut, CloudDepthOut, BlueNoise, cloud_size, frame_index, SkyLutOut, SkyLutTrans, sky_lut_size, CloudCurrent, CloudDepth, CloudHistory, CloudResolved, temporal_blend, has_history`. The camera far plane comes from the engine's `g_flFarPlane`.

### Debug views (`CloudDebugView`)
- `LayerIntervals`: R/G/B show each layer's march interval (verified working).
- `Density`: cloud opacity only.
- `SkyMask`: magenta where pixels are treated as sky. **Check this first** when verifying the sky.

---

## 4. Status

| Phase | Status | Notes |
|---|---|---|
| 0. API spikes | Partial | See section 2. Many items still unverified. |
| 1. Foundation (slabs, sky-pixel path, layers) | **Verified** | Debug intervals correct from below, inside and above. Clouds occluded properly by geometry. |
| 2. Baked noise | **Verified (compiles and renders)** | Tiling acceptable. Bake time 256 ms (Medium) and ~1.7 s (Ultra), synchronous. |
| 2b. Shape tuning | Superseded | Folded into the vertical-structure work; final shape tuning by eye later. |
| 3. Sky | **Done (user sign-off 2026-10-13)** | Horizon noise and below-horizon gray fixed (stable `GroundDistance`, quadratic atmosphere steps, horizon haze fade). |
| 4. Cloud lighting | **Done (user sign-off 2026-10-13)** | |
| 5. Performance | **Mostly done** | High at 2052x914: 4.10 ms -> 0.89 ms (all tiers 0.49 to 1.08 ms). Done: half-res compute trace, sky-view LUT, blue noise + temporal accumulation, non-uniform steps, detail fade with distance. Step counts retuned (High 40). Open: optional depth-aware upsample, empty-space skipping, async bake. |
| 6. Layers and weather | Partly done | Vertical structure (per-cloud tops, cloud type, anvil) and `StructuredBuffer` layers done and verified (needed some settings tuning). Rest open. |
| 7-9 | Not started | See section 5. |

The user's last reported state before Phase 3/4: tiling not bad; clouds too blobby and thick; wanted individual clouds, not a full-sky layer. Flat placeholder lighting was identified as part of the "blobby" look.

### Phase 5 baseline (2026-10-13)
Pose `(10524.2, -379.7, 2456.3)`, angles `(-14.5, 0, 0)` (looking ~14.5° up, toward the horizon), 10:00, 2 layers (tall convective + mid deck), 2052x914 (~1.9 MP). Off = 1.19 ms GPU.

| Tier | GPU median | Cost of the system | p95 |
|---|---|---|---|
| Low | 2.62 ms | 1.43 ms | 2.72 |
| Medium | 3.50 ms | 2.30 ms | 3.56 |
| High | 5.28 ms | 4.09 ms | 5.85 |
| Ultra | 7.10 ms | 5.90 ms | 7.66 |

Breakdown at High (same pose): sky only 1.17 ms, no aerial 3.91 ms, clouds only (our sky and aerial off) 3.24 ms. Sky + clouds-only exceed the full cost by ~0.3 ms, which is the shared fixed overhead (backbuffer copy + full-screen pass). Estimated split of High's 4.1 ms: **clouds ~2.9 ms (~70%)**, sky ~0.85 ms, aerial perspective ~0.2 ms, fixed ~0.3 ms. So reduced-resolution clouds plus temporal accumulation come first; the sky is second.

Runs repeat within ~0.1 ms. Tilting toward the horizon barely changed the cost, which points at fixed per-pixel work (sky atmosphere march, aerial perspective) rather than cloud coverage. Target: ~1 to 2 ms at High at this resolution.

### Phase 5 API findings (2026-10-13)
**Spike verified by the user:** compute dispatched from the post process's `CommandList` (`new CommandList(name)`, `Reset()`, `Attributes.Set`, `DispatchCompute( cs, w, h, 1 )` with thread counts, `InsertCommandList(..., Stage.AfterPostProcess, 199, ...)`), persistent `Texture.Create(...).WithUAVBinding().WithGPUOnlyUsage()` RGBA16F textures written as `RWTexture2D` and read next frame, ping-pong history, and `ReprojectFromLastFrameSs` (history calmer, grid locked while turning). No manual barriers were needed.
- Reduced-resolution targets: `CommandList.GetRenderTarget( name, sizeFactor, colorFormat, depthFormat, msaa, mips )` (sizeFactor 2 = half screen); release with `ReleaseRenderTarget`. Post process adds a command list with `BasePostProcess.InsertCommandList( cl, stage, order, name )`.
- Compute: `CommandList.DispatchCompute( ComputeShader, RenderTargetHandle.SizeHandle )` or `( cs, x, y, z )`; `UavBarrier(...)`, `ResourceBarrierTransition(...)`.
- Persistent history textures: `Texture.CreateRenderTarget().WithFormat(...).WithUAVBinding().Create()` or `Texture.CreateRenderTarget( name, format, size, oldTexture )` (recreates on resize). Ping-pong two of them like the engine SSR (`core/shaders/screen_space_reflections_cs.shader`, `PingIs0`).
- Reprojection: `core/shaders/common/classes/Motion.hlsl` -> `ReprojectFromLastFrameSs( worldPos )` (camera motion only), plus a generic `Motion::TemporalFilter` (3x3 clamp TAA) to crib from. So previous-frame matrices are provided by the engine.
- Blue noise: `core/textures/dev/blue_noise_256.vtex` ships with the engine (SSR uses a `BlueNoiseIndex`).
- Timing: `Sandbox.Diagnostics.PerformanceStats.GpuFrametime` works (used by `CloudBenchmark`). `GpuProfilerStats` has per-scope GPU timings (not yet tried).

### Proposed Phase 5 architecture
1. **Trace pass** (compute, 1/2 res on High/Ultra, 1/4 area on Low/Medium): clouds plus the smooth part of the sky (no sun disk, no stars) into an RGBA16F target (rgb radiance, a transmittance) and an R32F cloud depth (transmittance-weighted distance). Jitter = blue noise + frame index.
2. **Temporal pass** (compute): reproject the history with the cloud depth, 3x3 neighborhood clamp, blend ~0.9; reject harder within ~1 km of the camera; ping-pong two persistent textures.
3. **Composite** (the existing full-res blit, made cheap): depth-aware upsample of the cloud/sky buffer, add sun disk, moon and stars at full res, composite over the scene.
4. Then: empty-space skipping, aerial perspective on geometry moved off the per-pixel march (low-res or a small froxel/LUT), optional sky-view texture.

### Phase 5 progress
- **Step A done (2026-10-13):** clouds marched at reduced resolution by `cloud_trace_cs` (`Resolution` = Half default / Quarter / Full), bilinear upsample in the blit. All shared attributes are set on both the blit and the trace command list (`SetShared`). Same pose, 2052x914:

  | High | Full | Half |
  |---|---|---|
  | Total cost | 4.10 ms | **2.00 ms** |
  | Clouds only (incl. ~0.3 ms fixed) | 3.25 ms | 0.88 ms (clouds ~2.95 -> ~0.58 ms, ~5x) |
  | Sky only | 1.16 ms | 1.14 ms |

  Half, all tiers: Low 0.86, Medium 1.28, High 2.00, Ultra 2.85 ms. **The full-res sky (~0.85 ms) is now the largest cost at High.**
- Benchmark note: `Screen.Size` read at play start can be stale (logged 1024x1024 for a 2052x914 run); it is now logged at the end of the run.
- **Step D done (2026-10-13):** sky-view LUT. `sky_lut_cs` renders `SkyRadiance` (smooth sky incl. below-horizon haze/ground, no disk/moon/stars, 32 fixed steps, no jitter) into 320x192 RGBA16F `SkyLut` + `SkyLutTrans` (view transmittance) every frame, in the same command list as the trace (now inserted whenever the sky or the low-res trace is on). Mapping `SkyLutUv`/`SkyLutDirection`: u = world azimuth (WRAP), v = elevation relative to the geometric horizon with a sqrt warp per side (horizon at v = 0.5). The blit samples it and adds sun disk, moon and night sky at full res.
- **Step D measured (Half, 2052x914):** absolute GPU medians High 3.20 -> **2.31 ms**, High sky only 2.34 -> 1.44 ms (the sky got ~0.9 ms cheaper). This run's Off was 1.00 ms (was 1.20), so compare absolute medians, not "cost". Costs vs this Off: Low 0.67, Medium 0.83, **High 1.31**, Ultra 1.68 ms; sky only 0.44 ms. High went from 4.10 ms (original full-res) to ~1.1 to 1.3 ms.
- **Night sky rewritten (same step):** three star layers (dense faint / medium / sparse bright with halo) with pixel-footprint-aware sizing (energy-preserving, no shimmer), star density boosted near the galactic plane, Milky Way band (baked shape noise for mottling, dust lanes, warm core toward `GAL_CENTER`, faint colored nebulae), all rotating with `star_angle`. New properties `StarDensity`, `MilkyWayBrightness`.
- **Step B done (2026-10-13, user sign-off):** blue noise + temporal accumulation.
  - `cloud_trace_cs` jitter = `frac(blueNoise + frame_index * 0.618)` (engine `textures/dev/blue_noise_256.vtex`, loaded with `Texture.Load`), and a second output `CloudDepthOut` (R32F transmittance-weighted cloud distance, -1 = none). `MarchClouds` gained `out float cloudDist`.
  - `cloud_temporal_cs`: reproject with the cloud distance (direction-only for empty texels), clamp history to the current 3x3 mean +- 1.25 sigma, blend `TemporalBlend` (default 0.9) of history, scaled down to 0.6x for clouds within ~1 km; ping-pong `_historyA/_historyB`, the blit samples the resolved one.
  - History resets on resize, toggle, or a camera jump > 2000 units in one frame. `UavBarrier( Texture )` between trace and temporal (works).
  - New properties `Temporal` (default on), `TemporalBlend`, `Jitter` (BlueNoise / InterleavedGradient with per-frame offset; Temporal off always uses plain IGN, the pre-temporal look).
  - Measured: temporal adds ~0.05 ms (High 1.18 ms cost at Half). User saw no difference between blue noise and IGN. First version had drifting fringes on cloud edges and moving stripes from a quarter-texel offset (see gotchas); fixed and confirmed.
- **Current cost (Half, Temporal on, 2052x914):** Low 0.53, Medium 0.70, **High 1.18**, Ultra 1.55 ms (vs 1.43 / 2.30 / 4.09 / 5.90 at the start of the phase). Temporal costs ~0.05 ms; sky only ~0.3 ms.

### Phase 5: what is left
1. **Retune step counts per tier: done (2026-10-13).** User: 40 is the floor for High (lower is visibly worse). Result at the benchmark pose (Half, Temporal, 2052x914): **Low 0.49, Medium 0.57, High 0.89, Ultra 1.08 ms** (High was 4.09 ms at the start of Phase 5, 4.6x faster); High sky only 0.29, clouds only 0.70 ms. Details: with Temporal on (and Resolution not Full) view steps are Low 12 / Medium 20 / High 40 / Ultra 56; Temporal off keeps 16 / 32 / 64 / 96. Light steps unchanged (not jittered, so temporal does not help them). `ViewStepsOverride` (0 = auto) for A/B by eye; the benchmark logs steps per pass.
2. **Depth-aware upsample (Step C)**: only needed if halos appear where geometry meets sky. User has not reported geometry halos (the cloud-edge fringe was the quarter-texel bug).
3. **Empty-space skipping**: coarse pre-march to skip empty stretches of tall layers. Worth it if a cloudier/taller setup measures much slower than the benchmark pose.
4. **Async noise bake**: Ultra/High bake is ~1.7 s on the main thread (start-up and quality changes).
5. Dropped: Low-tier 2D cloud dome (Low already costs ~0.5 ms), sky inside the trace pass (replaced by the sky-view LUT).
6. Final per-tier table at a couple of poses (incl. a cloudier one) to close the phase.

---

## 5. Remaining phases

### Phase 5: Performance architecture (next priority after visual sign-off)
The current implementation is expensive: a light march at every cloud step and a per-pixel sky at full resolution.

- Render clouds at reduced resolution (1/4 area to 1/2 area by tier) into an offscreen target.
- Replace IGN jitter with blue noise (plus frame index); this needs a baked blue noise texture (void-and-cluster or a precomputed tile).
- Temporal accumulation with a history buffer and reprojection (camera motion; reject on disocclusion). **Reject history harder for samples within ~1 km** to avoid ghosting when flying through clouds.
- Depth-aware upsample and composite so clouds respect terrain edges.
- Empty-space skipping (cheap low-detail pre-march) and early-out on transmittance.
- Non-uniform step distribution that spends more steps near the camera; detail noise only within a limited distance.
- Possibly move the sky into a small sky-view texture updated on sun or altitude change instead of per pixel.
- Low tier: no raymarching; scrolling 2D cloud dome with fake lighting.
- Move the noise bake off the main thread (Ultra bake is ~1.7 s) if it becomes a problem.
- **Done when:** all four tiers run, with measured frame time recorded per tier.

### Phase 6: Multiple layers and weather
- ~~Per-layer cloud type~~ Done (2026-10-13): `CloudType`, `HeightVariation`, `Anvil` per layer; weather map G = regional height. Still open: anvils drifting downwind, per-cloud type variation within a layer.
- Cheap 2D cirrus layers (any number), with two-sided shading and a soft fade when the camera is near the plane.
- **Cross-layer shadowing:** the light march should account for layers between the sample and the sun (a cheap coverage lookup per layer, not a full march).
- `WeatherState` presets (clear, partly cloudy, overcast, storm) blending coverage, density, extinction, cloud darkening, fog, wind and sun dimming. Single entry point for gameplay to transition.
- Rain/precipitation hooks, lightning flashes (temporary inner-cloud light).
- **Done when:** transitions between presets are smooth with no popping.

### Phase 7: Cloud shadows on the ground
1. Cheap: a 2D shadow term from the layers' coverage and density sampled along the sun direction, applied in a post pass from depth-reconstructed world position.
2. Better: a top-down transmittance map snapped to the camera, fed into lighting through whatever hook s&box allows (shadow cookie or light modifier).
- The integration point with the engine's own sun shadows is the main unknown. Decide the hook early (investigate before building).
- **Done when:** moving shadows appear on terrain and respond to weather.

### Phase 8: Polish and tooling
- More debug views (noise slices, light-march optical depth, cost heat map).
- Editor gizmos for layer altitudes.
- Saved presets as resources; per-tier profiling.

### Phase 9 (later): Atmosphere LUTs and planets
- Replace the per-pixel single-scatter march with Hillaire-style LUTs (transmittance, multiple-scattering, sky-view, aerial-perspective froxels). Callers in the shader are written so the replacement is local to the atmosphere functions.
- Switch cloud layers from slabs to spherical shells; use the cancellation-safe sphere intersection (already used in the atmosphere code).
- Planet center in `double` on the C# side; send the shader only camera altitude, local up and sun direction in the local frame.
- Cubemap-style weather map (no pole pinching); horizon LOD; ground/atmosphere/space transitions.
- **Biggest unresolved question:** how the spherical world is represented in-engine (floating origin, chunked planet, etc.). s&box world coordinates are likely single-precision floats.
- Keep the flat-slab version as a cheap mode.

### Other backlog items
- Moonlight (second light source and tinted night ambient); the scene sun currently goes black below the horizon.
- ~~Milky Way and star variation~~ done procedurally (2026-10-13). Possible later: moon phases / textured moon.
- Curl-noise distortion of the detail sampling to break up the repeating 400 m detail tile pattern if it is still visible.
- Fix the near-camera cases: stable fog-like in-cloud falloff, minimum step size near the camera.
- Altitudes above ~80 km are clamped in the atmosphere code; real space transitions belong to Phase 9.

---

## 6. Known risks and gotchas

- **Unverified code.** Do not assume anything marked `API CHECK` compiles or behaves as written.
- **Tone-mapping space is unknown.** If the sky looks washed out, too dark or mismatched with terrain, tune `SkyExposure` and `CloudExposure` first, and find out where `Stage.AfterPostProcess` sits relative to the engine's tone mapping.
- **Saved inspector values override new code defaults.** After changing a property default in `SkyCloudSystem.cs`, remove and re-add the component or edit values by hand.
- **Scene sun feedback loop avoided on purpose:** the shader's sun color comes from the `SunColor` property, never from `Sun.LightColor`, because the component writes the tinted color back into the light.
- **`Sun.WorldRotation` is overwritten every frame** when `DriveSun` is on.
- **Layers must not overlap in altitude** (the shader assumes disjoint slabs).
- **Near-horizontal rays** produce very long march intervals; handled by a capped distance, growing step size, and a distance fade (`0.6 * max` to `max`) that hides the cap.
- **Sphere math at real scale:** never use the naive `b*b - c` form; use the closest-approach vector form. Even that form fails for the *near* hit when the origin is meters above a 6371 km sphere (float has ~0.5 m precision there): use `GroundDistance` (stable root of `a + t*mu + t^2/2R = 0`) for planet/ground hits.
- **Atmosphere step spacing must be non-uniform.** Horizon rays are ~1000 km long but their scattering is concentrated in the first tens of km; uniform steps plus jitter produced strong horizon noise. Both the view and sun marches use quadratic spacing.
- **Detail noise aliases at distance:** detail erosion fades out between 8 and 16 km (view-march steps there exceed the 400 m detail tile).
- **Light march cost:** grows as view steps times light steps. Phase 5 is the fix.
- **Detail erosion:** a flat threshold made the detail texture's cell pattern dominate at high strength. It now scales by `(1 - density)^2`. If the pattern is still visible, raise `DetailTilesPerKm` (4 to 6) or add distortion.
- **HLSL:** use `SampleLevel` (not `Sample`) inside loops; prefer integer PCG hashes over `sin`-based hashes.
- **Restart the editor after a shader compile failure.** After `sky_clouds.shader` failed to compile, the effect stayed invisible (no errors, debug views dead) even once it compiled cleanly; an engine restart fixed it, so a stale material/shader was cached. If the effect vanishes after shader edits, check `logs/sbox-dev.log` for "Shader compile failed", fix, then restart.
- **Reprojection convention:** `ReprojectFromLastFrameSs` returns a continuous screen position with pixel centers at +0.5 (same as `Depth::GetWorldPosition` input), so `prevUv = prevSs.xy * g_vInvViewportSize`. `Motion.hlsl`'s `+ 0.5` is only for integer thread-index input; copying it caused drift/warping while rotating. Sample history bilinearly.
- **A newly added ComputeShader can get stuck on an error shader** if it was created while its shader failed to compile ("DispatchComputeShader failed - bound pipeline does not have a compute shader"). Restart the editor after fixing the compile error.
- **Low-res texel -> full-res position must be the exact texel center** `(id + 0.5) * scale` in every pass (trace, temporal) so it matches the blit's bilinear upsample and the reprojection. Snapping to a full-res pixel center (`floor(...) + 0.5`) offset everything by a quarter texel, which the temporal pass re-applied every frame: drifting fringes on cloud edges and fine stripes that moved with the camera.
- **Hot reload keeps old field values and starts new fields at their defaults.** Lazy-allocation checks must test every resource (e.g. all render targets), not one representative, or newly added ones stay null ("Error when executing CommandList ... ArgumentNullException (Parameter 'texture')" from `UavBarrier`).
- **Compute shader includes:** use the engine DOF pattern, `#include "postprocess/shared.hlsl"` then `common/classes/Depth.hlsl` inside `CS` (no `COMMON` block). `system.fxc` + `common.fxc` alone leave `RemapValClamped` undefined in `Depth.hlsl` (its definition is not in the shipped shader sources).
- **HLSL parser:** the s&box ANTLR HLSL parser rejects global `static const float3 X = float3(...)` declarations ("Mismatched Token Exception"); scalar `static const float` is fine. Use `#define` for vector constants (the parser sees preprocessed source). Exponent literals, hex literals and array initializers were also removed as a precaution while diagnosing this; they were not proven to be the cause.

---

## 7. Tuning reference (current defaults)

| Setting | Default | Effect |
|---|---|---|
| `ExtinctionPerMeter` | 0.015 | Overall cloud opacity. First slider to touch for "too thick/too thin". |
| Layer coverage (low / high) | 0.35 / 0.25 | Where clouds exist (threshold). |
| `CloudType` | 0.6 (convective), 0.25 (mid deck) | Profile over each cloud's height: 0 stratus, 0.5 cumulus, 1 cumulonimbus. |
| `HeightVariation` | 0.85 (convective), 0 (mid deck) | 0 = all clouds fill the layer; 1 = tops from 12% to 100% of the layer. |
| `Anvil` | 0.5 (convective) | Spread of the tallest clouds near the layer top. |
| `WeatherInfluence` | 0.8 | How strongly the weather map opens and closes gaps. |
| `ShapeTilesPerKm` | 0.12 (low), 0.08 (high) | Higher = smaller, more numerous clouds. |
| `DetailTilesPerKm` | 2.5 | Higher = finer edge wisps. |
| `DetailStrength` | 0.6 | Edge erosion. Effective strength is 0.7 x slider, weighted toward cloud fringes. |
| Layer altitudes | 1200 to 6500 m, 7000 to 7800 m | Tall convective layer (small cumulus to towers), thin mid deck above. |
| `MaxCloudDistanceKm` | 40 | March distance cap. |
| `SkyExposure` / `CloudExposure` | 2.0 / 0.6 | Tone-mapping exposure. |
| `SkySunIntensity` | 22 | Sky brightness. |
| `SunIntensity` | 1.5 | Direct light on clouds. |
| `MaxSunElevation` | 70 | Noon sun height. |
| `HorizonFadeDegrees` | 15 | Below the horizon: angle over which the horizon haze fades into the `GroundAlbedo` ground. 90 = haze all the way down. |

---

## 8. Working agreements for the next assistant

- Verify s&box APIs against current docs before relying on them; whitelist errors cost a build cycle.
- When changing a file, read the current version first. The user has edited files in the past (for example the shader's phase function), so do not regenerate whole files from memory.
- Keep every API assumption marked `API CHECK`.
- Prefer small, testable steps: geometry first, then look, then performance.
- When behaviour is unknown (tone mapping, depth on sky pixels, light hooks), add a debug view or log rather than guessing.
- Tell the user honestly what has not been run.
