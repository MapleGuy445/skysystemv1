# Sky and Volumetric Cloud System: Project Plan

Handoff document for continuing this work in Claude Code. It records the goal, decisions, current state, remaining phases and the gotchas found so far.

**Engine:** s&box. **Language:** C# component plus an HLSL post-process shader.
**Last updated:** 2026-10-12.

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

I (the previous assistant) could not run or compile any code. **Everything below the "verified" line in section 4 is unverified.** Spots that depend on unverified s&box APIs are marked `API CHECK` in the code.

### s&box API whitelist
s&box compiles user code with a **whitelist**. `System.Threading.Tasks.Parallel` is **blocked**. Use `Sandbox.Utility.Parallel.For( int, int, Action<int> )` instead. If new code fails with `SB1000`, check the whitelist docs:
`https://github.com/Facepunch/sbox-docs/blob/master/docs/code/code-basics/api-whitelist.md`

### Confirmed API facts
- 3D textures: `Texture.CreateVolume( w, h, d, ImageFormat ).WithName(...).WithData( byte[], int ).Finish()`
- 2D textures: `Texture.Create( w, h, ImageFormat )...` (the `WithData` signature is assumed to match; not confirmed)
- `Attributes.Set( "name", value )` works for float, Vector3 and Vector4. Texture binding via the same call is assumed.
- Post process component: `BasePostProcess<T>`, drawn with `Blit( BlitMode.WithBackbuffer( material, Stage.AfterPostProcess, 200, false ), "name" )`.
- `Scene.Camera.ZFar` compiled and worked.

### Still unverified (`API CHECK` markers)
| Item | Where |
|---|---|
| `ImageFormat.RGBA8888` enum name | `CloudNoiseBaker.cs` |
| 2D `Texture.Create(...).WithData(...)` | `CloudNoiseBaker.cs` |
| `Attributes.Set( name, Texture )` for 2D and 3D | `SkyCloudSystem.cs` |
| `SamplerState` attribute syntax `Filter( MIN_MAG_MIP_LINEAR ); AddressU/V/W( WRAP )` | `cloud_density.hlsl` |
| `Depth::GetWorldPosition` on far-plane (sky) pixels | `sky_clouds.shader` |
| `DirectionalLight.LightColor`, `AmbientLight.Color`, `Rotation.LookAt( Vector3 )` | `SkyCloudSystem.cs` |
| `[Group( "..." )]` inspector attribute | `SkyCloudSystem.cs` |
| Whether `Stage.AfterPostProcess` runs before or after engine tone mapping | affects all exposure tuning |
| `Sandbox.Utility.Parallel.For` return value meaning (ignored by the baker) | `CloudNoiseBaker.cs` |

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
| `CloudNoiseBaker.cs` | CPU baker for tileable noise: shape 3D (RGBA8: R Perlin-Worley, GBA Worley fBm), detail 3D (RGB Worley fBm), weather 2D (R coverage, G reserved for cloud type). Uses `Sandbox.Utility.Parallel.For`. |
| `sky_clouds.shader` | Full-screen post-process: atmosphere (single scatter), sun/moon/stars, aerial perspective, slab intersection, layer sorting, cloud view march, cloud light march, composition. |
| `cloud_density.hlsl` | Included inside the shader's `PS` block. Declares noise textures, sampler and `layerN_noise` attributes. Provides `BaseCloudDensity`, `SampleDensityLight` (no detail), `SampleDensity` (full). |

### Core design decisions

- **Baked noise only** (shape, detail, weather). Runtime Perlin was the original biggest cost.
- **Slab clouds:** horizontal slabs `[bottom, top]` in meters above ground. Ray-slab intersection handles camera below, inside and above, plus near-horizontal rays (no divide by ~0).
- **Up to 3 volumetric layers**, sorted per ray by entry distance and marched front to back with one shared transmittance. Layers must not overlap in altitude.
- **Layer data packed into float4 attributes** (`layerN_range`, `layerN_params`, `layerN_noise`) instead of array attributes, to avoid depending on array support.
  - `range`: x bottom (m), y top (m), z coverage, w density
  - `params`: x shape freq (1/m), y/z wind offset (m), w detail strength
  - `noise`: x detail freq (1/m), y weather freq (1/m), z weather influence, w reserved
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
`sun_dir, sun_color, ambient_top, ambient_bottom, sun_disk_cos, moon_dir, moon_disk_cos, sky_enabled, sky_sun_intensity, sky_exposure, cloud_exposure, aerial_strength, ground_albedo, star_brightness, star_angle, horizon_fade, ground_z, max_cloud_distance, far_distance, extinction, step_count, light_steps, sky_steps, debug_mode, layer{0,1,2}_range, layer{0,1,2}_params, layer{0,1,2}_noise, ShapeNoise, DetailNoise, WeatherMap`

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
| 2b. Shape tuning | In progress | Defaults reduced after clouds looked too thick, blobby and sheet-like. Detail erosion formula changed after high strength "decimated" clouds; user has not yet confirmed the fix. |
| 3. Sky | **Compiles and renders; visuals not yet signed off** | Atmosphere, sun/moon disks, stars, aerial perspective, time of day, scene light sync. Scene light sync confirmed (sun rotation/colour and AmbientLight colour are written). |
| 4. Cloud lighting | **Compiles and renders; visuals not yet signed off** | Light march, multi-scatter, powder, ambient. |
| 5-9 | Not started | See section 5. |

The user's last reported state before Phase 3/4: tiling not bad; clouds too blobby and thick; wanted individual clouds, not a full-sky layer. Flat placeholder lighting was identified as part of the "blobby" look.

### First steps for the next session
1. Build. Fix any compile errors from the unverified APIs (section 2).
2. Use the `SkyMask` debug view to confirm sky classification.
3. Step `TimeOfDay` through 10, 18, 21, 2 and judge: sky color, sunset, stars, brightness balance vs. terrain (tone mapping assumption), cloud lighting.
4. Fly below, inside and above each layer and check lighting from every side.
5. Re-tune cloud shapes (see section 7) now that lighting can show depth.

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
- Per-layer **cloud type** via height gradient (stratus, cumulus, cumulonimbus, altocumulus) selected by data. The current gradient is hard-coded in `BaseCloudDensity`. The weather map's G channel is reserved for cloud type.
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
- Milky Way (needs a texture) and brighter/colored star variation.
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
- **HLSL parser:** the s&box ANTLR HLSL parser rejects global `static const float3 X = float3(...)` declarations ("Mismatched Token Exception"); scalar `static const float` is fine. Use `#define` for vector constants (the parser sees preprocessed source). Exponent literals, hex literals and array initializers were also removed as a precaution while diagnosing this; they were not proven to be the cause.

---

## 7. Tuning reference (current defaults)

| Setting | Default | Effect |
|---|---|---|
| `ExtinctionPerMeter` | 0.015 | Overall cloud opacity. First slider to touch for "too thick/too thin". |
| Layer coverage (low / high) | 0.35 / 0.25 | Where clouds exist (threshold). |
| `WeatherInfluence` | 0.8 | How strongly the weather map opens and closes gaps. |
| `ShapeTilesPerKm` | 0.12 (low), 0.08 (high) | Higher = smaller, more numerous clouds. |
| `DetailTilesPerKm` | 2.5 | Higher = finer edge wisps. |
| `DetailStrength` | 0.6 | Edge erosion. Effective strength is 0.7 x slider, weighted toward cloud fringes. |
| Layer altitudes | 1200 to 2200 m, 3500 to 4300 m | Low cumulus layer, thinner altocumulus layer. |
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
