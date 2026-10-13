// ============================================================================
//  cloud_density.hlsl  -  Phase 2/4 + vertical structure
//
//  Baked-noise cloud density. Include INSIDE the PS block of sky_clouds.shader,
//  after the global attribute declarations (needs ground_z).
//
//    BaseCloudDensity    cloud-type profile + per-cloud top + weather + shape
//    SampleDensityLight  cheap version for the light march (no detail erosion)
//    SampleDensity       full version used for the view march
//
//  Vertical model: every cloud's base sits on the layer bottom (real clouds
//  share a condensation level), but each cloud has its OWN top. The top comes
//  from a regional signal (weather map G: where towers cluster) and a per-cloud
//  signal (low-frequency Worley cells of the shape texture, ~one cell per
//  cloud). The cloud-type profile and the anvil are then evaluated in the
//  cloud's own normalized height, so small puffs and tall towers both get a
//  proper base, body and top.
//
//  API CHECK: SamplerState attribute syntax (Filter / AddressU/V/W).
// ============================================================================

Texture3D shapeNoise  < Attribute("ShapeNoise"); > ;
Texture3D detailNoise < Attribute("DetailNoise"); > ;
Texture2D weatherMap  < Attribute("WeatherMap"); > ;

SamplerState sCloudNoise < Filter( MIN_MAG_MIP_LINEAR ); AddressU( WRAP ); AddressV( WRAP ); AddressW( WRAP ); > ;

// One entry per active layer, sorted by altitude (lowest first) on the C# side.
// Must match CloudLayerGpu in SkyCloudSystem.cs (four float4s, 64 bytes).
struct CloudLayer
{
    float4 range;  // x bottom (m), y top (m), z coverage, w density
    float4 prm;    // x shape freq (1/m), y/z wind offset (m), w detail strength
    float4 nz;     // x detail freq (1/m), y weather freq (1/m), z weather influence, w reserved
    float4 shape;  // x cloud type (0 stratus, 0.5 cumulus, 1 cumulonimbus), y height variation, z anvil, w reserved
};

StructuredBuffer<CloudLayer> CloudLayers < Attribute("CloudLayers"); > ;
float layer_count < Attribute("layer_count"); > ;

float CloudRemap(float v, float a, float b, float c, float d)
{
    return c + (v - a) / max(b - a, 0.001) * (d - c);
}

// Density profile over a cloud's own height (hn: 0 = base, 1 = this cloud's top).
// type 0 = stratus (thin, flat), 0.5 = cumulus (rounded top), 1 = cumulonimbus
// (full column, flat top).
float CloudTypeProfile(float hn, float type)
{
    float stratus = smoothstep(0.0, 0.1, hn) * (1.0 - smoothstep(0.2, 0.6, hn));
    float cumulus = smoothstep(0.0, 0.15, hn) * (1.0 - smoothstep(0.5, 1.0, hn));
    float cbody   = smoothstep(0.0, 0.08, hn) * (1.0 - smoothstep(0.88, 1.0, hn));

    return type < 0.5
        ? lerp(stratus, cumulus, type * 2.0)
        : lerp(cumulus, cbody, type * 2.0 - 1.0);
}

// h: (out) height within THIS cloud, 0 = base, 1 = its top (used for lighting and detail)
float BaseCloudDensity(float3 pos, CloudLayer L, out float h)
{
    float thickness = max(L.range.y - L.range.x, 0.001);
    float hLayer = (pos.z - ground_z - L.range.x) / thickness;
    h = hLayer;
    if (hLayer < 0.0 || hLayer > 1.0)
        return 0.0;

    float3 p = float3(pos.xy + L.prm.yz, pos.z);

    // Weather map: R modulates coverage, G says where tall clouds cluster.
    float2 weather = weatherMap.SampleLevel(sCloudNoise, p.xy * L.nz.y, 0).rg;
    float coverage = saturate(L.range.z + (weather.r - 0.5) * 2.0 * L.nz.z);
    if (coverage <= 0.01)
        return 0.0;

    // ---- Per-cloud top height ----
    // Per-cloud signal: the low-frequency Worley channel of the shape texture on
    // a fixed slice gives roughly one cell per cloud. Combined with the regional
    // weather signal and squared so most clouds stay small and towers are rare.
    float cell = shapeNoise.SampleLevel(sCloudNoise, float3(p.xy * L.prm.x, 0.37), 0).g;
    float tall = saturate((cell * 0.55 + weather.g * 0.6 + coverage * 0.25) - 0.35) * 1.6;
    tall = saturate(tall);
    tall *= tall;
    float topFrac = lerp(1.0, lerp(0.12, 1.0, tall), L.shape.y);

    float hn = hLayer / topFrac;
    h = saturate(hn);
    if (hn >= 1.0)
        return 0.0;

    float grad = CloudTypeProfile(hn, L.shape.x);

    // ---- Anvil: tall clouds spread out near their top ----
    // Only clouds that reach high (topFrac near 1) get it; it widens coverage
    // and keeps density up just below the flat top.
    float anvil = L.shape.z * smoothstep(0.6, 0.95, topFrac) * smoothstep(0.65, 0.92, hn);
    grad = max(grad, anvil * (1.0 - smoothstep(0.93, 1.0, hn)));
    coverage = saturate(coverage + anvil * 0.45);

    if (grad <= 0.0)
        return 0.0;

    // Base shape: Perlin-Worley remapped by low-frequency Worley fBm.
    float4 s = shapeNoise.SampleLevel(sCloudNoise, p * L.prm.x, 0);
    float lowFbm = dot(s.gba, float3(0.625, 0.25, 0.125));
    float shape = saturate(CloudRemap(s.r, lowFbm - 1.0, 1.0, 0.0, 1.0)) * grad;

    // Coverage only decides WHERE clouds exist (the threshold); how thick they
    // are is controlled by Density and extinction.
    return saturate(CloudRemap(shape, 1.0 - coverage, 1.0, 0.0, 1.0));
}

// Cheap density for the sun-ward light march: no detail erosion.
float SampleDensityLight(float3 pos, CloudLayer L)
{
    float h;
    return BaseCloudDensity(pos, L, h) * L.range.w;
}

// Full density for the view march. detailWeight (0..1) fades the erosion out
// with distance: far away the march steps are larger than the detail tile, so
// sampling it only adds aliasing noise.
// h: (out) height within the cloud, 0 = base, 1 = top.
float SampleDensity(float3 pos, CloudLayer L, float detailWeight, out float h)
{
    float d = BaseCloudDensity(pos, L, h);
    if (d <= 0.0)
        return 0.0;
    if (detailWeight <= 0.0)
        return d * L.range.w;

    float3 p = float3(pos.xy + L.prm.yz, pos.z);

    // Detail erosion (only sampled where there is cloud): wispy near the base,
    // billowy near the top. Erosion fades out as density rises, so fringes get
    // eaten but cores keep the large-scale shape.
    float3 dn = detailNoise.SampleLevel(sCloudNoise, p * L.nz.x, 0).rgb;
    float detail = dot(dn, float3(0.625, 0.25, 0.125));
    detail = lerp(detail, 1.0 - detail, saturate(h * 10.0));

    float inv = 1.0 - d;
    float erosion = detail * L.prm.w * detailWeight * 0.7 * inv * inv;
    d = saturate(CloudRemap(d, erosion, 1.0, 0.0, 1.0));

    return d * L.range.w;
}
