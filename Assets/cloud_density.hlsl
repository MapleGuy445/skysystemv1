// ============================================================================
//  cloud_density.hlsl  -  Phase 2/4
//
//  Baked-noise cloud density. Include INSIDE the PS block of sky_clouds.shader,
//  after the global attribute declarations (needs ground_z).
//
//    BaseCloudDensity    height gradient + weather coverage + shape (no detail)
//    SampleDensityLight  cheap version for the light march (no detail erosion)
//    SampleDensity       full version used for the view march
//
//  API CHECK: SamplerState attribute syntax (Filter / AddressU/V/W) and
//  Texture3D declarations with Attribute(...).
// ============================================================================

Texture3D shapeNoise  < Attribute("ShapeNoise"); > ;
Texture3D detailNoise < Attribute("DetailNoise"); > ;
Texture2D weatherMap  < Attribute("WeatherMap"); > ;

SamplerState sCloudNoise < Filter( MIN_MAG_MIP_LINEAR ); AddressU( WRAP ); AddressV( WRAP ); AddressW( WRAP ); > ;

// x = detail freq (1/m), y = weather freq (1/m), z = weather influence, w = reserved
float4 layer0_noise < Attribute("layer0_noise"); > ;
float4 layer1_noise < Attribute("layer1_noise"); > ;
float4 layer2_noise < Attribute("layer2_noise"); > ;

float CloudRemap(float v, float a, float b, float c, float d)
{
    return c + (v - a) / max(b - a, 0.001) * (d - c);
}

// range: x = bottom, y = top, z = coverage, w = density
// prm:   x = shape freq (1/m), y/z = wind offset (m), w = detail strength
// nz:    see layerN_noise above
// h:     (out) normalized height inside the layer, 0 = base, 1 = top
float BaseCloudDensity(float3 pos, float4 range, float4 prm, float4 nz, out float h)
{
    float thickness = max(range.y - range.x, 0.001);
    h = (pos.z - ground_z - range.x) / thickness;

    // Height gradient: soft bottom, rounded top (cumulus-like).
    // Phase 6 swaps this for a per-cloud-type gradient.
    float grad = smoothstep(0.0, 0.15, h) * (1.0 - smoothstep(0.5, 1.0, h));
    if (grad <= 0.0)
        return 0.0;

    float3 p = float3(pos.xy + prm.yz, pos.z);

    // Weather map: modulates coverage across the sky.
    float weather = weatherMap.SampleLevel(sCloudNoise, p.xy * nz.y, 0).r;
    float coverage = saturate(range.z + (weather - 0.5) * 2.0 * nz.z);
    if (coverage <= 0.01)
        return 0.0;

    // Base shape: Perlin-Worley remapped by low-frequency Worley fBm.
    float4 s = shapeNoise.SampleLevel(sCloudNoise, p * prm.x, 0);
    float lowFbm = dot(s.gba, float3(0.625, 0.25, 0.125));
    float shape = saturate(CloudRemap(s.r, lowFbm - 1.0, 1.0, 0.0, 1.0)) * grad;

    // Coverage only decides WHERE clouds exist (the threshold); how thick they
    // are is controlled by Density and extinction.
    return saturate(CloudRemap(shape, 1.0 - coverage, 1.0, 0.0, 1.0));
}

// Cheap density for the sun-ward light march: no detail erosion.
float SampleDensityLight(float3 pos, float4 range, float4 prm, float4 nz)
{
    float h;
    return BaseCloudDensity(pos, range, prm, nz, h) * range.w;
}

// Full density for the view march. detailWeight (0..1) fades the erosion out
// with distance: far away the march steps are larger than the detail tile, so
// sampling it only adds aliasing noise.
float SampleDensity(float3 pos, float4 range, float4 prm, float4 nz, float detailWeight)
{
    float h;
    float d = BaseCloudDensity(pos, range, prm, nz, h);
    if (d <= 0.0)
        return 0.0;
    if (detailWeight <= 0.0)
        return d * range.w;

    float3 p = float3(pos.xy + prm.yz, pos.z);

    // Detail erosion (only sampled where there is cloud): wispy near the base,
    // billowy near the top. Erosion fades out as density rises, so fringes get
    // eaten but cores keep the large-scale shape.
    float3 dn = detailNoise.SampleLevel(sCloudNoise, p * nz.x, 0).rgb;
    float detail = dot(dn, float3(0.625, 0.25, 0.125));
    detail = lerp(detail, 1.0 - detail, saturate(h * 10.0));

    float inv = 1.0 - d;
    float erosion = detail * prm.w * detailWeight * 0.7 * inv * inv;
    d = saturate(CloudRemap(d, erosion, 1.0, 0.0, 1.0));

    return d * range.w;
}
