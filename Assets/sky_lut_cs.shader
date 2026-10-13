// ============================================================================
//  sky_lut_cs  -  Phase 5: sky-view LUT
//
//  Renders the smooth sky (atmosphere, below-horizon haze and ground; no sun
//  disk, moon or stars) once per frame into a small texture indexed by view
//  direction (SkyLutUv / SkyLutDirection in cloud_common.hlsl):
//    SkyLutOut   rgb = HDR sky radiance
//    SkyLutTrans rgb = view transmittance along the direction (dims and reddens
//                      the sun disk, moon and stars near the horizon)
//  sky_clouds.shader samples it per pixel instead of marching the atmosphere.
//  The texel count is tiny, so it uses a fixed, generous step count and no jitter.
// ============================================================================

MODES
{
    Default();
}

CS
{
    #include "postprocess/shared.hlsl"
    #include "common/classes/Depth.hlsl"
    #include "cloud_common.hlsl"

    RWTexture2D<float4> SkyLutOut   < Attribute("SkyLutOut"); > ;
    RWTexture2D<float4> SkyLutTrans < Attribute("SkyLutTrans"); > ;
    float2 sky_lut_size < Attribute("sky_lut_size"); > ;

    [numthreads(8, 8, 1)]
    void MainCs(uint3 id : SV_DispatchThreadID)
    {
        if (id.x >= (uint)sky_lut_size.x || id.y >= (uint)sky_lut_size.y)
            return;

        float camAltKm = clamp((g_vCameraPositionWs.z * INCH_TO_M - ground_z) * 0.001, 0.0005, 80.0);
        float3 p0 = float3(0.0, 0.0, PLANET_R + camAltKm);

        float2 uv = (float2(id.xy) + 0.5) / sky_lut_size;
        float3 rd = SkyLutDirection(uv, SkyHorizonElevation(camAltKm));

        float3 viewT;
        float3 radiance = SkyRadiance(p0, camAltKm, rd, 0.5, 32, viewT);

        SkyLutOut[id.xy] = float4(radiance, 1.0);
        SkyLutTrans[id.xy] = float4(viewT, 1.0);
    }
}
