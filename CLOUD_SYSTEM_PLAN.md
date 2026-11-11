# Sky and Volumetric Cloud System: Project Plan

Handoff document for continuing this work in Claude Code. It records the goal, the current architecture, what is verified, what is left, and the gotchas found so far.

**Engine:** s&box (26.10.27c at last check). **Language:** C# components plus HLSL post-process and compute shaders.
**Last updated:** 2026-10-30 (full review after Phase 5).

---

## 1. Goals and where they stand

| Goal | State |
|---|---|
| Multiple volumetric cloud layers with sun-aware lighting | **Met.** Up to 8 slab layers, per-cloud vertical structure (cloud type, height variation, anvils), light march + multi-scatter + powder + height-graded ambient. |
| Analytic sky with sun, moon, stars and a day/night cycle | **Met**, with one gap: no moonlight (the scene sun goes black at night, night ambient is a fixed dark blue). Night sky has three star layers and a procedural Milky Way. |
| Performance tiers for a range of hardware | **Met.** Half/High ~1.1 ms at 1.9 MP (2.6 ms at 4.4 MP); Low to Ultra 1.5 to 3.2 ms at 4.4 MP. Full is ~4x Half. |
| Clouds look good from any angle (below, inside, above any layer) | **Mostly met.** Below/above/at layer edges verified on 2026-10-30 (no crawling, far clouds kept). Flying inside a cloud close to the camera has not been re-checked since those changes and is the expected weak spot (backlog: near-camera falloff). |
| Weather presets that blend over time | **Not started** (Phase 6). |
| Cloud shadows on the ground | **Not started** (Phase 7). The engine hook is the main unknown. |
| Real-scale planet | **Deferred on purpose** (Phase 9). |

### Scope decision (still valid)
The system uses **flat horizontal slabs** in a flat world (Z up). The atmosphere math assumes a virtual spherical planet *below* the flat world, which gives a correct sky and horizon without world-representation problems. Planet support (Phase 9) should not require rewrites of the noise, lighting, layering or temporal code.

---

## 2. Environment, tooling and API notes (read first)

### Tooling
- **The assistant can inspect and drive the running editor** with the engine's MCP bridge, `sbox-cli` (`T:/SteamLibrary/steamapps/common/sbox/bin/managed/sbox-cli.exe`), run from the project folder:
  - `--call editor_status` (compile state), `--call camera_screenshot '{"width":1280,"height":720,"includeUi":false}'` (renders the scene camera, prints a PNG path), `--call run_csharp '{"path":"<file>"}'` (runs C# in the editor; read or temporarily change component settings, then restore them).
  - Agent instructions: `sbox-cli --skill sbox-cli`.
- **Editor log:** `T:/SteamLibrary/steamapps/common/sbox/logs/sbox-dev.log` (shader compiles, C# errors, `CloudBenchmark` results, noise bake timings).
- **API docs:** `bin/managed/Sandbox.Engine.xml`; engine shader sources in `core/shaders`.

### s&box rules that bite
- **Whitelist:** `System.Threading.Tasks.Parallel` is blocked; use `Sandbox.Utility.Parallel.For`. Background work: `GameTask.RunInThreadAsync` (works).
- **Shader includes do not trigger recompiles** (see gotchas): after editing an `.hlsl`, touch the `.shader` files and check the log.

### Verified in the running engine
`Texture.CreateVolume/Create(...).WithData(...).Finish()` with `ImageFormat.RGBA8888`; UAV textures `Texture.Create(...).WithUAVBinding().WithGPUOnlyUsage()` (RGBA16F, R32F); `Attributes.Set` for float/Vector2/3/4, 2D/3D textures and `GpuBuffer<T>` (as `StructuredBuffer` and `RWStructuredBuffer`); `CommandList` (`Reset`, `Attributes.Set`, `DispatchCompute( cs, x, y, z )` with thread counts, `UavBarrier( Texture )`) inserted with `BasePostProcess.InsertCommandList( cl, Stage.AfterPostProcess, 199, name )`; `ComputeShader`; `Texture.Load( "textures/dev/blue_noise_256.vtex" )`; `ReprojectFromLastFrameSs`; `g_flFarPlane`, `g_vViewportSize`; `GameTask.RunInThreadAsync`; `PerformanceStats.GpuFrametime / GpuFrameNumber`; `DirectionalLight.LightColor`, `AmbientLight.Color`, `Rotation.LookAt`; `[Group]`; `SamplerState` attribute syntax.

### Still unknown
- **Where `Stage.AfterPostProcess` sits relative to the engine's tone mapping.** The shader tone-maps sky and clouds itself; if the sky looks washed out or mismatched with terrain, tune `SkyExposure` / `CloudExposure` first.
- **The engine hook for ground cloud shadows** (Phase 7).

### Units
- s&box world units are **inches** (1 unit = 0.0254 m). Cloud math in the shaders is in **meters**, atmosphere math in **kilometers**. World **Z is up**; layer altitudes are meters above `GroundLevel`.

---

## 3. Architecture

### Files
| File | Role |
|---|---|
| `Code/SkyCloudSystem.cs` | The component (`BasePostProcess<SkyCloudSystem>`), placed on the camera. Settings, quality tiers, time of day and sun driving, CPU atmosphere (`AtmosphereCpu`: sun tint at camera altitude), ambient colors, scene light sync, wind, background noise bake, layer buffer upload, render-target management, and recording of all GPU passes. Also `CloudLayerSettings`, `CloudLayerGpu`, the enums. |
| `Code/CloudNoiseBaker.cs` | Tileable noise: shape 3D (R Perlin-Worley, GBA Worley fBm), detail 3D (RGB Worley fBm), weather 2D (R coverage, G regional cloud height). `Bake*Data` is pure CPU (worker thread), `Create*` uploads (main thread); 1x1 placeholders. |
| `Code/CloudBenchmark.cs` | Measurement: pins the camera, freezes time and wind, runs Off/Low/Medium/High/Ultra plus a High breakdown (sky only / no aerial / clouds only), logs GPU medians to the editor log. |
| `Assets/cloud_common.hlsl` | Shared by every pass: attributes, constants, `CloudRay`, atmosphere (single scattering, `GroundDistance`, `SkyRadiance`, sky-view LUT mapping), cloud lighting, the march (`MarchClouds`, `CloudMarchSample`), low-res target helpers (`CloudTraceSize`, `CloudTexUv`). |
| `Assets/cloud_density.hlsl` | Noise textures, sampler, `CloudLayer` struct + `CloudLayers` buffer, `CloudTypeProfile`, `BaseCloudDensity` (per-cloud top, type profile, anvil, coverage, shape), `SampleDensityLight`, `SampleDensity` (with distance-faded detail erosion). |
| `Assets/sky_lut_cs.shader` | Sky-view LUT: smooth sky (no disk/moon/stars) + view transmittance, 320x192, every frame. |
| `Assets/cloud_trace_cs.shader` | Cloud march per low-res texel (or per pixel at Full): colour + transmittance and cloud distance. |
| `Assets/cloud_temporal_cs.shader` | Reprojection + neighborhood clamp + blend into ping-pong history. |
| `Assets/sky_clouds.shader` | Full-screen composite: sky from the LUT plus sun disk, moon and night sky at full res, aerial perspective on geometry, clouds from the resolved texture. Debug views. (Its per-pixel `MarchClouds` path, `cloud_lowres = 0`, is no longer used.) |

### Frame pipeline
1. **C# `OnUpdate`:** time of day / sun direction, atmosphere tint, ambient, scene light sync, wind offsets, background noise bake.
2. **C# `Render`:** sets all shared attributes on both the blit and one compute `CommandList` (`SetShared`), uploads the layer buffer, then records into that command list:
   1. `sky_lut_cs` (if `ReplaceSky`),
   2. `cloud_trace_cs` over the target capacity,
   3. `UavBarrier`, then `cloud_temporal_cs` (if `Temporal`),
   
   and inserts it at `AfterPostProcess` order 199, before the blit at order 200.
3. **Blit (`sky_clouds.shader`):** background (LUT sky or the scene with aerial perspective) composited with `bg * cloud.a + cloud.rgb`.

### Core design decisions
- **Baked noise only**; baked on a worker thread. Until the first bake finishes the sky renders with 1x1 placeholder noise and no cloud layers (clouds fade in through the history).
- **Slab layers:** up to 8 in one `StructuredBuffer<CloudLayer>` (4 float4s, 64 bytes; C# `CloudLayerGpu` must match). C# uploads only enabled layers, sorted by altitude, and skips any layer overlapping the one below (warning). The march walks layers upward for rising rays and downward for falling rays (entry order for disjoint slabs). One shared transmittance, front to back.
- **Vertical structure:** bases on the layer bottom; each cloud's top = `lerp(1, lerp(0.12, 1, tall^2), HeightVariation)` of the layer height, `tall` mixing a per-cloud Worley cell, the weather map G and coverage. Type profile, anvil, ambient and detail use the cloud's own normalized height. Towers = one tall convective layer.
- **Sample placement (`StepSchedule = CameraAnchored`, default):** every cell of `t(u) = 5000 m * (exp(u) - 1)` with `du = 0.2 / steps` inside each layer (step length grows with distance only), budget = cells to reach `MaxCloudDistanceKm` (max 1024). No empty-space skipping. `PerLayer` (the original, entry-relative placement) is kept for comparison only.
- **Low-res targets:** allocated by C# at a capacity (`max(Screen.Size, 3840x2160) / div`; Full: `max(Screen.Size, 2560x1440)`); every pass derives the region it uses from `g_vViewportSize`. The temporal pass keeps each resolve's region size in `CloudSizeState` (2 slots) so history is read at the size it was written.
- **Jitter:** blue noise + golden-ratio frame offset (or IGN with per-frame offset); static IGN when `Temporal` is off.
- **Temporal:** reproject with the cloud distance (direction-only for empty texels), clamp to the current 3x3 mean +- 1.25 sigma, blend `TemporalBlend` (0.9), reduced to 0.6x for clouds within ~1 km and capped while the lighting changes quickly (`LightingAwareBlend`). Resets on toggle, target reallocation, or a camera jump > 2000 units.
- **Sun tint by altitude:** `SunTransLut` (C# `AtmosphereCpu`, 32 entries 0 to 20 km, every frame); each cloud sample is lit with the tint at its own altitude.
- **Sky:** sky-view LUT (u = world azimuth, v = elevation relative to the geometric horizon with a sqrt warp per side, horizon at v = 0.5); sun disk, moon and night sky added per pixel at full res. Atmosphere is single scattering (Rayleigh, Mie g = 0.76, ozone) on a virtual 6371 km planet; `AtmosphereCpu` mirrors it so cloud light, scene light and sky agree.
- **Tone mapping:** the shader tone-maps sky and clouds (`1 - exp(-x * exposure)`), scene colour untouched.
- **Aerial perspective:** on geometry (> 100 m, per pixel, `SkySteps / 2` steps) and on clouds (at their transmittance-weighted mean distance, in the trace).

### Cloud lighting model
Light march toward the sun with growing steps (3 to 8 samples, no detail), length scaled by layer thickness (capped at 3 km) and stretched at low sun; Beer-Lambert; 3-octave multi-scatter; dual-lobe Henyey-Greenstein normalized so isotropic = 1; powder on sun-facing edges (faded when backlit); ambient from a ground-lit bottom to a sky-coloured top over the cloud's own height; direct light is the atmosphere-tinted sun colour.

### Quality tiers (`CloudQuality`)
| Tier | View steps (Temporal on / off) | Light steps | Aerial steps (geometry) | Shape / detail noise |
|---|---|---|---|---|
| Low | 12 / 16 | 3 | 8 | 64³ / 16³ |
| Medium | 20 / 32 | 4 | 12 | 64³ / 16³ |
| High | 40 / 64 | 6 | 16 | 128³ / 32³ |
| Ultra | 56 / 96 | 8 | 24 | 128³ / 32³ |

View steps are per layer for `PerLayer`; for `CameraAnchored` the base grid has 2 x steps cells and each layer gets about `steps`. `ViewStepsOverride` > 0 replaces the table. The sky LUT always uses 32 steps.

### Shader attribute contract (names must match C# and HLSL)
- Shared (blit + compute): `sun_dir, sun_color, ambient_top, ambient_bottom, sun_disk_cos, moon_dir, moon_disk_cos, sky_enabled, sky_sun_intensity, sky_exposure, cloud_exposure, aerial_strength, ground_albedo, star_brightness, star_angle, horizon_fade, ground_z, max_cloud_distance, extinction, step_schedule, step_count, light_steps, sky_steps, debug_mode, cloud_div, cloud_capacity, CloudLayers, layer_count, ShapeNoise, DetailNoise, WeatherMap`.
- Shared (sun tint): `SunTransLut, sun_lut_top`. Blit only: `CloudTex, cloud_lowres, SkyLut, SkyLutTrans, star_density, star_size, milky_way`.
- Compute only: sky LUT `SkyLutOut, SkyLutTrans, sky_lut_size`; trace `CloudOut, CloudDepthOut, BlueNoise, frame_index, jitter_mode`; temporal `CloudCurrent, CloudDepth, CloudHistory, CloudResolved, temporal_blend, has_history, CloudSizeState, size_slot`.
- Engine globals used: `g_flFarPlane`, `g_vViewportSize`, `g_vInvViewportSize`, `g_vCameraPositionWs`, `g_flTime`.

### Debug views (`CloudDebugView`)
`LayerIntervals` (R/G/B by layer index), `Density` (cloud opacity), `SkyMask` (magenta = treated as sky; check first when the sky looks wrong).

---

## 4. Status

| Phase | Status | Notes |
|---|---|---|
| 1. Foundation (slabs, sky pixels, layers) | **Done** | |
| 2. Baked noise | **Done** | Background bake (~1.7 to 2.6 s for 128³, plus an engine warning that the task ran > 1 s without yielding; harmless). |
| 3. Sky | **Done** | Plus sky-view LUT and the new night sky. |
| 4. Cloud lighting | **Done** | |
| 5. Performance | **Done** (user sign-off, commit 5631076) | Final measurement 2026-10-30 below. Optional extras listed in section 5. |
| 6. Layers and weather | **Partly done** | Vertical structure, cloud types, layer buffer done. Weather presets, cirrus, cross-layer shadowing, rain/lightning open. |
| 7. Ground cloud shadows | Not started | |
| 8. Polish and tooling | Not started | |
| 9. Planet | Deferred | |

### Phase 5 results (benchmark pose, 2052x914, 2 layers, 10:00)
| Step | Low | Medium | High | Ultra |
|---|---|---|---|---|
| Baseline, full-res per-pixel march | 1.43 | 2.30 | 4.09 | 5.90 ms |
| A: half-res compute trace | 0.86 | 1.28 | 2.00 | 2.85 ms |
| D: sky-view LUT | 0.67 | 0.83 | 1.31 | 1.68 ms |
| B: blue noise + temporal | 0.53 | 0.70 | 1.18 | 1.55 ms |
| Step retune (12/20/40/56) | **0.49** | **0.57** | **0.89** | **1.08 ms** |

Cost = GPU median minus the "Off" median (Off ~1.0 to 1.2 ms). Temporal costs ~0.05 ms; High sky only ~0.29 ms.

### Final Phase 5 measurement (2026-10-30, after the schedule / sizing / Full changes)
Run by the assistant through `sbox-cli` in play mode (runtime-only settings: reference pose, 10:00, 40 km, code-default layers). Game view maximized at **3440x1288 (4.4 MP, 2.4x the pixels of the table above)**; Off median ~11.8 ms (heavier editor frame), p95 within ~1.4 ms of the medians. Compare within this table, not with the one above.

| Configuration (cost in ms) | Low | Medium | High | Ultra |
|---|---|---|---|---|
| Half, CameraAnchored (default) | 1.50 | 1.77 | **2.63** | 3.23 |
| Half, PerLayer | 1.28 | 1.58 | **2.46** | 3.06 |
| Full, CameraAnchored (refine rounded up, before the fix) | 4.12 | 5.64 | 9.90 | 15.67 |
| Half, CameraAnchored, inside the tall layer (refine rounded up) | 1.61 | 2.15 | 3.73 | 4.93 |

- The two Half rows have **the same raw GPU medians** (High 14.34 vs 14.39 ms; Off differed by 0.2 ms between runs), so the camera-anchored schedule costs the same as the old one once its per-layer refinement rounds to the nearest power of two. Rounding up (first version) cost ~36% more.
- Scaled to the old 1.9 MP benchmark size, Half/High is ~1.1 ms, in line with the 0.89 ms measured before.
- **Full is ~4x Half** (High ~10 ms at 4.4 MP even with its targets capped at 2560 wide): only for screenshots or very strong GPUs.
- High sky only: 0.6 to 0.8 ms at 4.4 MP. Inside the tall layer costs ~10 to 15% more than the reference pose.

---

## 5. What is left

### Closing Phase 5
1. ~~Re-benchmark~~ done 2026-10-30 (section 4). To repeat: keep the editor focused (unfocused editors cap at 90 fps and the numbers become noisy), maximize the game view, then drive `CloudBenchmark` in play mode via `sbox-cli` `run_csharp` (set `RunOnStart = false`, `UseStartPose = false`, pose, settings, enable, `StartRun()`) and read the log.
2. **Visual sign-off of the step counts under `CameraAnchored`** with nearest-power-of-two refinement (each layer now gets 0.7x to 1.4x of the tier's steps, ~1x on average, like `PerLayer`). High 40 was the agreed floor under `PerLayer`.

### Optional performance/quality items (only if needed)
- **Depth-aware upsample** at geometry silhouettes: only if halos appear where objects meet sky (none reported).
- **Empty-space skipping**: if a sparse tall layer measures much slower than the benchmark pose.
- **Prefiltered far clouds**: far cells of the anchored schedule are long (~t x du: ~15 km at 200 km on High). Temporal jitter turns this into a converging estimate, but mipmapped noise sampled by step length would make far clouds cleaner without temporal.
- **Clean-up:** remove the unused per-pixel `MarchClouds` path from `sky_clouds.shader` (and `cloud_lowres`) once Full via compute is settled; `PerLayer` schedule likewise once `CameraAnchored` has been lived with.

### Phase 6: Layers and weather
**Step 1 done (2026-11-11): presets, blending, API.** `WeatherPreset` asset (`.weather`, Code/Weather/WeatherPreset.cs): per-layer coverage, density, cloud type, height variation, anvil (matched to `SkyCloudSystem.Layers` by index), extinction scale, wind, sun dimming, cloud ambient scale, haze (Mie multiplier, also in `AtmosphereCpu`), precipitation, lightning per minute. `WeatherSystem` component (runs in the editor): `SetWeather(preset, seconds)` with a smoothstep blend that starts from the current state; `Current` (blended `WeatherState`), `OnLightning(Vector3)`; sets `SkyCloudSystem.Weather`, which then replaces the layer looks and wind (wind strengthens ~15%/km aloft) and scales extinction, sun, cloud ambient and haze. Starter presets in `Assets/weather/`: clear, partly_cloudy, overcast, storm (first guesses). Verified in play mode. Known issue: storm towers look like pointed cones (per-cloud tops follow a smooth noise gradient); fix with the storm work in step 2.
**Step 2 done (2026-11-11): automatic cycle (`WeatherSystem.AutoCycle`) and tower shape.**
- The weather state is a point (moisture, instability). Presets have a `CyclePosition` there (clear 0.1/0.15, partly cloudy 0.4/0.4, towering cumulus 0.6/0.75 (new preset), overcast 0.9/0.2, storm 0.85/0.95); the weather shown is an inverse-distance (power 4) blend of `CyclePresets`, so it changes continuously.
- Regimes drawn every 4 to 16 weather hours (/`Changeability`): fair 45%, convective 25%, frontal 20%, stormy 10% (base moisture/instability ranges in `DrawRegime`). Moisture relaxes toward the regime over ~3 h, instability over ~2 h, plus a frame-rate-independent random wander.
- Time of day: instability +-0.35 x `DiurnalStrength` x moisture, peaking at 15:00 and lowest at 03:00. Convective regimes have only a moderate base so towers are an afternoon thing (a first version peaked overnight).
- Storms burn out: after 1 to 3 h of storm conditions (moisture > 0.7, instability > 0.75) a clearing regime takes over.
- Clock: the sky's day cycle if `DayLengthSeconds` > 0, else `HoursPerRealMinute`. `SetWeather` in cycle mode steers to the preset's position, holds a few hours, then evolves on. Read-only `Moisture`, `Instability`, `RegimeName`, `HoursUntilRegimeChange`.
- Verified in play mode over 2 x 60 weather hours: fair -> convective -> frontal -> fair; frontal -> stormy (lightning ~5/min) -> frontal -> fair -> stormy -> automatic clearing.
- Tower shape (cloud_density.hlsl): the height signal is sampled at half the shape frequency; ordinary cumulus tops vary in the lower 12 to 45% of the layer, towers rise steeply (smoothstep 0.55 to 0.72) to a broad 85 to 100% plateau, replacing cone-shaped towers.
**Step 3 (next):** lightning lighting the clouds from inside, rain hooks.

- `WeatherState` presets (clear, partly cloudy, overcast, storm) blending coverage, density, extinction, cloud darkening, fog/aerial, wind and sun dimming; one entry point for gameplay to transition. **Done when** transitions are smooth with no popping.
- Cheap 2D cirrus layers (any number), two-sided shading, soft fade near the plane.
- Cross-layer shadowing: the light march accounts for layers between the sample and the sun (cheap coverage lookup per layer).
- Rain/precipitation hooks; lightning flashes (temporary in-cloud light).
- Still open from the vertical-structure work: anvils drifting downwind, per-cloud type variation within a layer.

### Phase 7: Cloud shadows on the ground
1. Cheap: 2D shadow term from layer coverage/density sampled along the sun direction, applied from depth-reconstructed world position.
2. Better: a top-down transmittance map snapped to the camera, fed into lighting through whatever hook s&box allows (shadow cookie / light modifier). **Investigate the hook first.** **Done when** moving shadows appear on terrain and respond to weather.

### Phase 8: Polish and tooling
More debug views (noise slices, light-march optical depth, cost heat map), editor gizmos for layer altitudes, presets saved as resources, per-tier profiling.

### Phase 9 (deferred): planet
Hillaire-style atmosphere LUTs (transmittance, multi-scattering, aerial-perspective froxels; the sky-view LUT already exists), spherical cloud shells, double-precision planet center on the C# side, cubemap weather map, space transitions. Biggest open question: how a spherical world is represented in-engine. Keep the flat mode as the cheap option.

### Backlog
- **Moonlight:** a second light at night and a tinted night ambient (the scene sun goes black below the horizon).
- Moon phases / textured moon.
- Near-camera in-cloud case: stable fog-like falloff, minimum step size near the camera.
- Curl-noise distortion of detail sampling if the 400 m detail tile repeats visibly.
- Altitudes above ~80 km are clamped in the atmosphere code (space belongs to Phase 9).

### Design notes (not implemented)
**Depth-aware upsample (joint bilateral).** The trace writes the scene depth it used; the blit weights the 4 nearest low-res texels by bilinear weight x depth similarity (`1 / (eps + |zFull - z_i| / zFull)`), falling back to the closest-depth texel; optionally checkerboard min/max depth per 2x2. ~0.05 ms.

**Empty-space skipping.** A: after K empty samples take 2 to 3x longer steps, step back on the first hit. B: drive A with a weather-map + height-only test (no 3D shape sample). C: 1/8-res ray-bounds pre-pass (first/last non-zero density, dilated), then march only that range. Measure a sparse and an overcast pose first; A before C.

**Far clouds.** Mip the shape/detail 3D textures (`WithMips`) and sample at `lod = log2(stepLength / texelSize)` (texel ~65 m at 0.12 tiles/km, 128³), so long steps average instead of alias. Alternative: an analytic coverage-only far band blended in where the march gets sparse.

---

## 6. Gotchas (learned the hard way)

### Engine and tooling
- **Editing an included `.hlsl` does NOT recompile the shaders that include it.** Touch or re-save the `.shader` files (`sky_clouds`, `cloud_trace_cs`, `cloud_temporal_cs`, `sky_lut_cs`) and check the log for "Compiling: ...". Otherwise old code keeps running silently.
- **Restart the editor after a shader compile failure** if the effect stays invisible, and after a `ComputeShader` was created while its shader failed ("DispatchComputeShader failed - bound pipeline does not have a compute shader"): a stale error shader stays cached.
- **`Screen.Size` is not the render size in the editor** (3456x1409, later 160x29, for the same viewport). Never size render targets from it; derive sizes on the GPU from `g_vViewportSize`. `CameraComponent.SceneCamera` is not accessible from game code.
- **Hot reload keeps old field values and starts new fields at defaults.** Lazy-allocation checks must test every resource, or new ones stay null. This includes field and auto-property initializers (`= new()`, `{ get; } = new()`): an existing component can get them as null after a reload (WeatherSystem.Current did, 2026-11-11). Create such objects on first use (`_x ??= new ...`) instead.
- **A GameResource created with `create_asset` json can stay cached with DEFAULT values in the running editor** (the compiled file is right, `ResourceLibrary.Get` returns the stale instance; `asset_write` did not refresh it). A restart fixes it; in-session, `preset.LoadFromJson( File.ReadAllText( source ) )` on the cached instance refreshes it.
- **`set_component` (sbox-cli) reports component-reference properties as "Applied" when given a plain component id, but leaves them null.** Set component references with `run_csharp` (`ws.Clouds = clouds`) and read them back to verify. Asset paths (e.g. a `.weather` preset) do work as plain strings.
- **Saved inspector values override new code defaults.** New properties appear with their code default; changed defaults do not apply to existing scenes.
- **Compute shader includes:** `#include "postprocess/shared.hlsl"` then `common/classes/Depth.hlsl` inside `CS` (engine DOF pattern). `system.fxc` + `common.fxc` alone leave `RemapValClamped` undefined.
- **HLSL parser:** rejects global `static const float3 X = float3(...)`; use `#define`. Avoid `line` as an identifier (HLSL keyword).
- **Use `SampleLevel` inside loops; prefer integer PCG hashes.**

### Rendering math
- **Reprojection:** `ReprojectFromLastFrameSs` returns a continuous screen position (pixel centers at +0.5), so `prevUv = prevSs.xy * g_vInvViewportSize`. `Motion.hlsl`'s `+ 0.5` is for integer thread indices only.
- **Low-res texel to screen position must be the exact texel center** `(id + 0.5) * scale` in every pass; snapping to a full-res pixel center caused a quarter-texel drift that the temporal pass re-applied every frame.
- **Sample placement must not be relative to the layer entry**: the entry of a near-horizontal ray moves by (camera height change) / rd.z, so entry-relative steps crawl when the camera moves vertically and become kilometres long on long rays. Use the camera-anchored schedule. (A step-length cap was tried and removed: it cut off far clouds near layer boundaries.)
- **Cloud sunlight must be tinted at the cloud's altitude, not the camera's.** Since Phase 4 the atmosphere tint of the sun was computed once at the camera altitude and applied to every cloud, so moving the camera up or down relit all clouds (strongest near sunrise and sunset); it also tinted the scene sun light and the ground bounce by camera altitude. Fixed (2026-11-11): C# fills `SunTransLut` (32 entries, 0 to 20 km above `GroundLevel`) each frame; `CloudLighting` uses `SunTransmittanceAt(sample altitude)`; ground bounce, scene sun light and the below-horizon ground use the ground-level entry. `sun_color` is now untinted.
- **Step length must not depend on the camera's height or the layer, and nothing inside a layer may be skipped.** Long steps systematically make clouds lighter and thinner, so any schedule whose step length followed the camera changed the lighting as it moved: entry-relative steps (crawling stripes), per-ray power-of-two refinement (horizontal bars), per-pixel level dithering (warping side-on), per-layer levels (lighting shifting with height). Coarse empty-space skipping on camera-anchored coarse cells also failed: which cloud parts were skipped depended on where the cells fell, so lighting crawled across clouds (and thin dark squiggles appeared on far edges). Fixed (2026-11-11): `CameraAnchored` samples every cell `t(u) = 5000 m * (exp(u) - 1)`, `du = 0.2 / steps` (High: ~25 m near, ~50 m at 5 km, ~275 m at 50 km) inside each layer; budget = cells needed to reach `MaxCloudDistanceKm` (cannot run out), capped at 1024 with a fixed-distance fade if the cap bites. Quality first; costs more than before.
- **Full resolution needs temporal accumulation too**: a per-pixel march with a static jitter pattern looks grainy/pixelated.
- **Temporal history lags fast lighting changes, worst on cloud edges** (bright outlines at sunrise/sunset with a short day length that fade a moment later). The 3x3 clamp is tight inside clouds but wide on edges, whose neighborhood mixes cloud and empty sky, so old lighting survives there. Fixed (2026-11-11) in C# (`LightingAwareBlend`): the per-frame relative change of sun light, ambient and sun direction caps the history weight so the lag stays under 1% (`weight <= 1 - change / 0.01`). Measured: still or a 20-minute day keeps `TemporalBlend`; a 2-minute day 0.70; a 30-second day 0 (no history, more grain while the sun is low). `EffectiveTemporalBlend` shows the weight in use.
- **Sphere math at real scale:** use the closest-approach form, and `GroundDistance` (stable root of `a + t*mu + t^2/2R = 0`) for near hits a few meters above a 6371 km sphere.
- **Atmosphere step spacing must be non-uniform** (quadratic) for horizon rays.
- **Detail noise aliases at distance:** erosion fades out between 8 and 16 km. **Detail erosion** scales by `(1 - density)^2`; if the cell pattern shows, raise `DetailTilesPerKm` or add distortion.
- **Stars must be sized in pixels**, not angles, or bright stars become washed-out discs.
- **Scene sun feedback loop avoided on purpose:** the shader's sun colour comes from `SunColor`, never from `Sun.LightColor` (the component writes the tinted colour back into the light). `Sun.WorldRotation` is overwritten every frame when `DriveSun` is on.
- **Layers must not overlap in altitude.**

---

## 7. Tuning reference (code defaults)

Existing scenes keep their saved values (the development scene currently uses Ultra, Full, `MaxCloudDistanceKm` 200, a second layer at 13.6 to 16.8 km and very low coverages).

| Setting | Default | Effect |
|---|---|---|
| `Quality` | High | Step and noise-size tier (section 3). |
| `Resolution` | Half | Full / Half / Quarter (per axis); all go through the compute trace. |
| `Temporal` / `TemporalBlend` | on / 0.9 | Frame blending; higher = smoother, slower to react. |
| `Jitter` | BlueNoise | Or InterleavedGradient (no visible difference observed). |
| `StepSchedule` | CameraAnchored | PerLayer only for comparison. |
| `ViewStepsOverride` | 0 | > 0 forces view steps (A/B by eye). |
| `MaxCloudDistanceKm` | 40 | March distance; far clouds fade over the last 40%. |
| `ExtinctionPerMeter` | 0.015 | Overall cloud opacity. |
| Layers | 1200 to 6500 m (coverage 0.35, type 0.6, height variation 0.85, anvil 0.5); 7000 to 7800 m (coverage 0.25, type 0.25) | Tall convective layer + thin mid deck. |
| `ShapeTilesPerKm` / `DetailTilesPerKm` / `WeatherTilesPerKm` | 0.12 (0.08 mid deck) / 2.5 / 0.02 | Cloud size / edge wisps / weather pattern size. |
| `WeatherInfluence` / `DetailStrength` | 0.8 / 0.6 | Weather map strength / edge erosion. |
| `SkyExposure` / `CloudExposure` | 2.0 / 0.6 | Tone-mapping exposure. |
| `SkySunIntensity` / `SunIntensity` / `AmbientIntensity` | 22 / 1.5 / 1 | Sky brightness / direct light on clouds / cloud ambient. |
| `AerialPerspective` | 1 | Haze on geometry and clouds. |
| `MaxSunElevation` / `SunAzimuth` | 70 / 90 | Noon sun height / sunrise direction. |
| `HorizonFadeDegrees` | 15 | Below-horizon haze fade into `GroundAlbedo`; 90 = haze all the way down. |
| `StarBrightness` / `StarDensity` / `StarSize` / `MilkyWayBrightness` | 1 / 1 / 1 / 1 | Night sky. |

---

## 8. Working agreements for the next assistant

- Verify s&box APIs against `Sandbox.Engine.xml` and engine sources before relying on them; mark new assumptions `API CHECK` and resolve them in the running editor.
- **Verify in the editor, not by assumption:** after shader edits touch the `.shader` files, wait for `editor_status` to show no compile in progress, check the log for compile errors, and take a `camera_screenshot`. When changing settings for a test via `run_csharp`, restore them afterwards and say so.
- Read a file before changing it; the user edits files and settings between sessions.
- Small, testable steps: geometry first, then look, then performance. Benchmark with `CloudBenchmark` when performance is the question.
- When behaviour is unknown, add a debug view, a log, or a `run_csharp` probe rather than guessing.
- Tell the user honestly what has not been run.
