// ============================================================================
//  cloud_common.hlsl  -  shared by sky_clouds.shader (PS) and cloud_trace_cs.shader (CS)
//
//  Attributes, constants, the atmosphere (single scattering, virtual spherical
//  planet, km) and the cloud march. Cloud distances are METERS, atmosphere math
//  is KILOMETERS. All attributes are set by SkyCloudSystem.cs, on both the
//  full-screen blit and the trace command list.
//
//  Include after postprocess/shared.hlsl and common/classes/Depth.hlsl.
// ============================================================================

#ifndef CLOUD_COMMON_HLSL
#define CLOUD_COMMON_HLSL

// Sun / moon
float3 sun_dir          < Attribute("sun_dir"); > ;           // direction TOWARD the sun
float3 sun_color        < Attribute("sun_color"); > ;         // cloud direct light (tinted by atmosphere, includes intensity)
float3 ambient_top      < Attribute("ambient_top"); > ;
float3 ambient_bottom   < Attribute("ambient_bottom"); > ;
float  sun_disk_cos     < Attribute("sun_disk_cos"); > ;
float3 moon_dir         < Attribute("moon_dir"); > ;
float  moon_disk_cos    < Attribute("moon_disk_cos"); > ;

// Sky
float  sky_enabled       < Attribute("sky_enabled"); > ;
float  sky_sun_intensity < Attribute("sky_sun_intensity"); > ;
float  sky_exposure      < Attribute("sky_exposure"); > ;
float  cloud_exposure    < Attribute("cloud_exposure"); > ;
float  aerial_strength   < Attribute("aerial_strength"); > ;
float3 ground_albedo     < Attribute("ground_albedo"); > ;
float  star_brightness   < Attribute("star_brightness"); > ;
float  star_angle        < Attribute("star_angle"); > ;
float  horizon_fade      < Attribute("horizon_fade"); > ;     // sine of the below-horizon haze fade angle

// World / clouds
float ground_z           < Attribute("ground_z"); > ;
float max_cloud_distance < Attribute("max_cloud_distance"); > ;
float extinction         < Attribute("extinction"); > ;

// Quality / debug
float step_count   < Attribute("step_count"); > ;
float light_steps  < Attribute("light_steps"); > ;
float sky_steps    < Attribute("sky_steps"); > ;
float debug_mode   < Attribute("debug_mode"); > ;

static const float INCH_TO_M  = 0.0254;
static const int   MAX_LAYERS = 8;   // must match SkyCloudSystem.MaxLayers
static const int   MAX_STEPS  = 128;
static const float PI_F       = 3.14159265;

// Cloud density (declares the noise textures and the CloudLayers buffer).
#include "cloud_density.hlsl"

// Interleaved gradient noise (cheap per-pixel jitter; Phase 5 swaps in blue noise + frame index).
float InterleavedGradientNoise(float2 px)
{
    return frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
}

// ------------------------------------------------------------------
// View ray for a full-resolution screen position (pixel centers at +0.5).
// ro is in meters; maxT is the cloud march limit in meters.
// ------------------------------------------------------------------
struct CloudRay
{
    float3 worldPos;   // world units (inches)
    float3 ro;         // meters
    float3 rd;
    float  sceneDist;  // meters
    bool   isSky;
    float  maxT;       // meters
};

CloudRay MakeCloudRay(float2 screenPos)
{
    CloudRay r;
    r.worldPos = Depth::GetWorldPosition(screenPos);
    float3 roWs = g_vCameraPositionWs;
    r.rd = normalize(r.worldPos - roWs);
    r.ro = roWs * INCH_TO_M;
    r.sceneDist = length(r.worldPos - roWs) * INCH_TO_M;
    r.isSky = r.sceneDist >= g_flFarPlane * INCH_TO_M * 0.99; // engine global (common.fxc), world units
    r.maxT = r.isSky ? max_cloud_distance : min(r.sceneDist, max_cloud_distance);
    return r;
}

// ==================================================================
//  ATMOSPHERE (single scattering, virtual spherical planet, km)
//  Camera sits at (0, 0, R + altitude); world Z is up.
//  Phase 9 can replace this with LUTs without touching the callers.
// ==================================================================
static const float  PLANET_R = 6371.0;
static const float  ATMO_H   = 100.0;
static const float  ATMO_R   = PLANET_R + ATMO_H;
static const float  H_RAY    = 8.0;
static const float  H_MIE    = 1.2;
// Vector constants are macros: the s&box HLSL parser rejects global
// "static const float3 X = float3(...)" declarations.
#define BETA_R float3(0.0058, 0.0135, 0.0331)
static const float  BETA_M   = 0.021;
#define BETA_O float3(0.00065, 0.001881, 0.000085)

float PhaseRayleigh(float mu)
{
    return 3.0 / (16.0 * PI_F) * (1.0 + mu * mu);
}

float PhaseMie(float mu, float g)
{
    float g2 = g * g;
    return 3.0 / (8.0 * PI_F) * ((1.0 - g2) * (1.0 + mu * mu))
         / ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * mu, 0.001), 1.5));
}

// Ray vs sphere centered at the origin. Cancellation-safe form.
// Returns (tNear, tFar) or (-1,-1) on a miss.
float2 AtmoSphereHit(float3 o, float3 d, float r)
{
    float b = dot(o, d);
    float3 qc = o - b * d;
    float ql = length(qc);
    float h2 = (r - ql) * (r + ql);
    if (h2 < 0.0)
        return float2(-1.0, -1.0);
    float h = sqrt(h2);
    return float2(-b - h, -b + h);
}

// Distance (km) along a ray with vertical component mu to the virtual planet
// surface, from altitude a (km); -1 if the ray clears the planet.
// Solves a + t*mu + t^2/(2R) = 0 (curvature approximation, accurate well past
// cloud altitudes) using the root form without cancellation. The full sphere
// hit at R = 6371 km has no float precision left a few meters above the
// surface, which made pixels randomly flip between ground and sky.
float GroundDistance(float a, float mu)
{
    float disc = mu * mu - 2.0 * a / PLANET_R;
    if (mu >= 0.0 || disc < 0.0)
        return -1.0;
    return 2.0 * a / (-mu + sqrt(disc));
}

// Optical depth from P toward the sun. Returns false if the planet blocks the sun.
bool AtmoLightDepth(float3 P, float3 sun, out float3 tau)
{
    tau = float3(0.0, 0.0, 0.0);

    float r = length(P);
    if (GroundDistance(max(r - PLANET_R, 0.0005), dot(P, sun) / r) > 0.0)
        return false;

    float2 top = AtmoSphereHit(P, sun, ATMO_R);
    float len = max(top.y, 0.0);

    // Quadratic step spacing: a low sun's path runs ~1000 km, but nearly all
    // of its optical depth is in the first few tens of km.
    float odR = 0.0, odM = 0.0, odO = 0.0;
    [unroll] for (int j = 0; j < 4; j++)
    {
        float u0 = j * 0.25;
        float u1 = u0 + 0.25;
        float uS = u0 + 0.125;
        float ds = len * (u1 * u1 - u0 * u0);
        float h = max(length(P + sun * (len * uS * uS)) - PLANET_R, 0.0);
        odR += exp(-h / H_RAY) * ds;
        odM += exp(-h / H_MIE) * ds;
        odO += max(0.0, 1.0 - abs(h - 25.0) / 15.0) * ds;
    }

    tau = BETA_R * odR + BETA_M * 1.1 * odM + BETA_O * odO;
    return true;
}

// In-scattered radiance along a view ray of length tmax (km), plus the
// transmittance of that segment.
float3 AtmoInscatter(float3 p0, float3 rd, float tmax, int steps, float jitter,
                     float3 sun, float sunIntensity, out float3 transmittance)
{
    float invN = 1.0 / steps;
    float odR = 0.0, odM = 0.0, odO = 0.0;
    float3 sumR = float3(0.0, 0.0, 0.0);
    float3 sumM = float3(0.0, 0.0, 0.0);

    [loop] for (int i = 0; i < steps; i++)
    {
        // Quadratic step spacing, dense near the camera. A near-horizontal
        // ray is ~1000 km long but only stays in the low, dense air for the
        // first few tens of km; with uniform steps one jittered sample
        // decided the whole result and neighboring pixels disagreed (noise).
        float u0 = i * invN;
        float u1 = u0 + invN;
        float uS = (i + jitter) * invN;
        float ds = tmax * (u1 * u1 - u0 * u0);
        float3 P = p0 + rd * (tmax * uS * uS);
        float h = max(length(P) - PLANET_R, 0.0);

        float dR = exp(-h / H_RAY) * ds;
        float dM = exp(-h / H_MIE) * ds;
        float dO = max(0.0, 1.0 - abs(h - 25.0) / 15.0) * ds;

        float3 tauL;
        if (AtmoLightDepth(P, sun, tauL))
        {
            // View optical depth up to the middle of this step.
            float3 tau = BETA_R * (odR + 0.5 * dR) + BETA_M * 1.1 * (odM + 0.5 * dM)
                       + BETA_O * (odO + 0.5 * dO) + tauL;
            float3 att = exp(-tau);
            sumR += dR * att;
            sumM += dM * att;
        }

        odR += dR; odM += dM; odO += dO;
    }

    transmittance = exp(-(BETA_R * odR + BETA_M * 1.1 * odM + BETA_O * odO));

    float mu = dot(rd, sun);
    return sunIntensity * (sumR * BETA_R * PhaseRayleigh(mu) + sumM * BETA_M * PhaseMie(mu, 0.76));
}

// ------------------------------------------------------------------
// Smooth sky radiance (HDR, no sun disk / moon / stars) for one direction,
// plus the view transmittance along it. Below the horizon: lit ground seen
// through the haze, blended into the horizon haze over horizon_fade so there
// is no seam. Evaluated per texel of the sky-view LUT (sky_lut_cs).
// ------------------------------------------------------------------
float3 SkyRadiance(float3 p0, float camAltKm, float3 rd, float jitter, int steps, out float3 viewT)
{
    float tGround = GroundDistance(camAltKm, rd.z);

    if (tGround > 0.0)
    {
        float3 ins = AtmoInscatter(p0, rd, tGround, max(steps / 2, 4), jitter, sun_dir, sky_sun_intensity, viewT);
        float3 ground = ins + ground_albedo * (sun_color * saturate(sun_dir.z) * 0.3183 + ambient_bottom) * viewT;

        // Horizon haze at the same azimuth, aimed just above the geometric horizon.
        float dip = sqrt(2.0 * camAltKm / PLANET_R); // sine of the horizon depression
        float2 hz = rd.xy;
        float hl = length(hz);
        hz = hl > 0.0001 ? hz / hl : float2(1.0, 0.0);
        float hzZ = 0.002 - dip;
        float3 rdH = float3(hz * sqrt(1.0 - hzZ * hzZ), hzZ);

        float3 hT;
        float tH = max(AtmoSphereHit(p0, rdH, ATMO_R).y, 0.01);
        float3 horizon = AtmoInscatter(p0, rdH, tH, steps, jitter, sun_dir, sky_sun_intensity, hT);

        float f = smoothstep(0.0, max(horizon_fade, 0.001), -rd.z - dip);
        return lerp(horizon, ground, f);
    }

    float tmax = max(AtmoSphereHit(p0, rd, ATMO_R).y, 0.01);
    return AtmoInscatter(p0, rd, tmax, steps, jitter, sun_dir, sky_sun_intensity, viewT);
}

// ------------------------------------------------------------------
// Sky-view LUT mapping (after Hillaire 2020). u = world azimuth, v = elevation
// relative to the geometric horizon with a square-root warp on each side, so
// texels bunch up at the horizon where the sky changes fastest. The horizon
// itself sits exactly at v = 0.5. Sample with WRAP in u and CLAMP in v.
// ------------------------------------------------------------------
float SkyHorizonElevation(float camAltKm)
{
    return -asin(sqrt(2.0 * camAltKm / PLANET_R)); // the horizon dips below 0 with altitude
}

float2 SkyLutUv(float3 rd, float horizonElev)
{
    float u = atan2(rd.y, rd.x) / (2.0 * PI_F) + 0.5;
    float elev = asin(clamp(rd.z, -1.0, 1.0)) - horizonElev;
    float up = 0.5 * PI_F - horizonElev;
    float down = 0.5 * PI_F + horizonElev;
    float v = elev >= 0.0
        ? 0.5 + 0.5 * sqrt(saturate(elev / up))
        : 0.5 - 0.5 * sqrt(saturate(-elev / down));
    return float2(u, v);
}

float3 SkyLutDirection(float2 uv, float horizonElev)
{
    float az = (uv.x - 0.5) * 2.0 * PI_F;
    float up = 0.5 * PI_F - horizonElev;
    float down = 0.5 * PI_F + horizonElev;
    float a = 2.0 * (uv.y - 0.5);
    float elev = a >= 0.0 ? a * a * up : -a * a * down;
    float e = elev + horizonElev;
    return float3(cos(e) * cos(az), cos(e) * sin(az), sin(e));
}

// ------------------------------------------------------------------
// Cloud helpers
// ------------------------------------------------------------------
float CloudHG(float cosTheta, float g)
{
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI_F * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 0.001), 1.5));
}

// Dual-lobe phase (forward + weak backward), normalized so isotropic == 1.
// 'c' shrinks the eccentricity for higher multiple-scattering octaves.
float CloudDualPhase(float cosTheta, float c)
{
    return 4.0 * PI_F * (0.7 * CloudHG(cosTheta, 0.6 * c) + 0.3 * CloudHG(cosTheta, -0.25 * c));
}

// Ray vs horizontal slab [h0, h1] (absolute Z). Returns (tNear, tFar), or
// (-1,-1) on a miss. Handles camera below / inside / above and near-horizontal rays.
float2 SlabInterval(float oz, float dz, float h0, float h1, float maxT)
{
    if (abs(dz) < 0.0001)
    {
        return (oz >= h0 && oz <= h1) ? float2(0.0, maxT) : float2(-1.0, -1.0);
    }

    float ta = (h0 - oz) / dz;
    float tb = (h1 - oz) / dz;

    float tn = max(min(ta, tb), 0.0);
    float tf = min(max(ta, tb), maxT);

    return (tf > tn) ? float2(tn, tf) : float2(-1.0, -1.0);
}

// Light reaching a point inside a cloud: sun-ward light march, multi-scatter
// approximation, powder term, plus height-graded ambient.
float3 CloudLighting(float3 pos, CloudLayer L,
                     float hFrac, float cosSun, float localDens, int lightSteps)
{
    // Capped so a tall convective layer does not make the light march too
    // coarse for the small clouds at its bottom.
    float thickness = clamp(L.range.y - L.range.x, 1.0, 3000.0);

    // Low sun means the light path crosses the slab at a shallow angle, so
    // stretch the steps to still reach the cloud edge.
    float sunElev = clamp(sun_dir.z, 0.2, 1.0);
    float baseStep = thickness * 0.08 / sunElev;

    float tau = 0.0;
    float dist = 0.0;
    [loop] for (int k = 0; k < 8; k++)
    {
        if (k >= lightSteps) break;
        float dl = baseStep * (1.0 + k); // steps grow with distance
        float3 lp = pos + sun_dir * (dist + 0.5 * dl);
        tau += SampleDensityLight(lp, L) * extinction * dl;
        dist += dl;
    }

    // Multiple-scattering approximation: three octaves, each with weaker
    // extinction, weaker contribution and a rounder phase function.
    float scatter = 0.0;
    float a = 1.0, b = 1.0, c = 1.0;
    [unroll] for (int n = 0; n < 3; n++)
    {
        scatter += b * CloudDualPhase(cosSun, c) * exp(-tau * a);
        a *= 0.5; b *= 0.5; c *= 0.5;
    }

    // Powder: dark edges on sun-facing sides. Fades out when looking toward
    // the sun (backlit), where it would wrongly darken the silver lining.
    float powder = 1.0 - exp(-localDens * extinction * 240.0);
    float powderWeight = saturate((1.0 - cosSun) * 0.5) * 0.7;
    float direct = scatter * lerp(1.0, powder, powderWeight);

    float3 ambient = lerp(ambient_bottom, ambient_top, hFrac) * lerp(0.5, 1.0, hFrac);

    return sun_color * direct + ambient;
}

// ------------------------------------------------------------------
// Debug: each layer's march interval (R/G/B cycle by layer index).
// ------------------------------------------------------------------
float3 CloudLayerIntervals(CloudRay r)
{
    int layerCount = clamp((int)layer_count, 0, MAX_LAYERS);
    float3 dbg = float3(0.0, 0.0, 0.0);
    [loop] for (int k = 0; k < layerCount; k++)
    {
        CloudLayer Lk = CloudLayers[k];
        float2 ivk = SlabInterval(r.ro.z, r.rd.z, ground_z + Lk.range.x, ground_z + Lk.range.y, r.maxT);
        if (ivk.y > ivk.x)
        {
            int c = k - (k / 3) * 3;
            float3 tint = c == 0 ? float3(1.0, 0.0, 0.0) : (c == 1 ? float3(0.0, 1.0, 0.0) : float3(0.0, 0.0, 1.0));
            dbg += tint * (saturate((ivk.y - ivk.x) / 4000.0) * 0.8 + 0.2);
        }
    }
    return dbg;
}

// ------------------------------------------------------------------
// The cloud march for one view ray.
// Returns rgb = tone-mapped cloud colour with aerial perspective applied,
// premultiplied by opacity; a = transmittance. Composite: bg * a + rgb.
// cloudDist: transmittance-weighted mean distance of the cloud (meters), or
// -1 if the ray saw no cloud. Used for temporal reprojection.
// ------------------------------------------------------------------
float4 MarchClouds(CloudRay r, float jitter, out float cloudDist)
{
    cloudDist = -1.0;

    float3 ro = r.ro;
    float3 rd = r.rd;
    float maxT = r.maxT;

    // Atmosphere frame (for aerial perspective on the clouds).
    float camAltKm = clamp((ro.z - ground_z) * 0.001, 0.0005, 80.0);
    float3 p0 = float3(0.0, 0.0, PLANET_R + camAltKm);
    int skySteps = clamp((int)sky_steps, 4, 32);
    int lightSteps = clamp((int)light_steps, 1, 8);

    // C# uploads only active layers, sorted by altitude (lowest first). Since
    // slabs do not overlap, walking them upward for rising rays and downward
    // for falling rays visits them in entry order: no per-pixel sort needed.
    // Layers behind the ray (e.g. below the camera on a rising ray) simply
    // produce an empty interval.
    int layerCount = clamp((int)layer_count, 0, MAX_LAYERS);
    bool rising = rd.z >= 0.0;

    // ---- March, front to back, one shared transmittance ----
    int steps = clamp((int)step_count, 1, MAX_STEPS);

    float transmittance = 1.0;
    float3 scatter = float3(0.0, 0.0, 0.0);
    float cosSun = dot(rd, sun_dir);

    // Transmittance-weighted mean distance of the cloud contribution,
    // used afterwards to apply aerial perspective to the clouds.
    float weightSum = 0.0;
    float distSum = 0.0;

    [loop] for (int s = 0; s < layerCount; s++)
    {
        CloudLayer L = CloudLayers[rising ? s : layerCount - 1 - s];
        if (!(L.range.y > L.range.x && L.range.w > 0.0 && L.range.z > 0.0)) continue;

        float2 t = SlabInterval(ro.z, rd.z, ground_z + L.range.x, ground_z + L.range.y, maxT);
        if (t.y <= t.x) continue;

        float D = t.y - t.x;
        float thickness = L.range.y - L.range.x;

        // Uniform steps for rays that cross the slab; steps bunch up near
        // the camera for long near-horizontal rays (exponent 1 -> 2).
        float expo = lerp(1.0, 2.0, saturate(D / (thickness * 8.0)));

        [loop] for (int j = 0; j < MAX_STEPS; j++)
        {
            if (j >= steps) break;

            float u0 = (float)j / steps;
            float u1 = (float)(j + 1) / steps;
            float uS = ((float)j + jitter) / steps;

            float tS = t.x + D * pow(uS, expo);
            float dt = D * (pow(u1, expo) - pow(u0, expo));

            float3 pos = ro + rd * tS;
            float detailW = 1.0 - smoothstep(8000.0, 16000.0, tS);
            float hCloud;
            float dens = SampleDensity(pos, L, detailW, hCloud);

            // Fade toward the distance cap so the cutoff is invisible.
            dens *= 1.0 - smoothstep(0.6 * max_cloud_distance, max_cloud_distance, tS);

            if (dens > 0.001)
            {
                float sigma = dens * extinction;
                float stepT = exp(-sigma * dt);
                float w = transmittance * (1.0 - stepT);

                // Skip the (expensive) light march for negligible contributions.
                if (w > 0.0005)
                {
                    // Ambient gradient over the cloud's own height, so a small
                    // puff in a tall layer still gets a bright top.
                    float3 lighting = CloudLighting(pos, L, hCloud, cosSun, dens, lightSteps);

                    scatter += w * lighting;
                    weightSum += w;
                    distSum += w * tS;
                }

                transmittance *= stepT;
                if (transmittance < 0.01) break;
            }
        }

        if (transmittance < 0.01) break;
    }

    float alpha = 1.0 - transmittance;

    // ---- Cloud colour: tone-map, then aerial perspective at the cloud distance ----
    float3 cloudRad = 1.0 - exp(-scatter * cloud_exposure);

    if (alpha > 0.003 && weightSum > 0.0 && aerial_strength > 0.001)
    {
        float avgKm = max((distSum / weightSum) * 0.001, 0.01);
        float3 Tc;
        float3 insC = AtmoInscatter(p0, rd, avgKm, max(skySteps / 2, 4), jitter, sun_dir, sky_sun_intensity, Tc);
        float3 insCTM = 1.0 - exp(-insC * sky_exposure);
        cloudRad = lerp(cloudRad, cloudRad * Tc + alpha * insCTM, aerial_strength);
    }

    if (weightSum > 0.0)
        cloudDist = distSum / weightSum;

    return float4(cloudRad, transmittance);
}

#endif // CLOUD_COMMON_HLSL
