using Sandbox;
using System;
using System.Collections.Generic;

// ============================================================================
//  WeatherPreset  -  Phase 6
//
//  One weather situation (clear, partly cloudy, overcast, storm, ...) stored as
//  an asset (.weather). A WeatherSystem blends between presets over time and
//  feeds the result to SkyCloudSystem, which then uses it instead of its own
//  layer sliders. Layer ALTITUDES stay in the scene (SkyCloudSystem.Layers);
//  a preset only says what the clouds in each layer look like.
// ============================================================================

[AssetType( Name = "Weather Preset", Extension = "weather", Category = "Sky" )]
public sealed class WeatherPreset : GameResource
{
	/// <summary>Cloud look per layer, matched to SkyCloudSystem.Layers by index (lowest layer first in the list you set up there).</summary>
	[Property, Group( "Clouds" )] public List<WeatherLayer> Layers { get; set; } = new()
	{
		new WeatherLayer(),
		new WeatherLayer { Coverage = 0.25f, CloudType = 0.25f, HeightVariation = 0f, Anvil = 0f },
	};

	/// <summary>Multiplier on SkyCloudSystem.ExtinctionPerMeter: how dense and dark clouds look.</summary>
	[Property, Group( "Clouds" ), Range( 0.25f, 4f )] public float ExtinctionScale { get; set; } = 1f;

	// ---- Wind ----

	[Property, Group( "Wind" ), Range( 0, 100 )] public float WindSpeed { get; set; } = 5f; // m/s
	[Property, Group( "Wind" ), Range( 0, 360 )] public float WindDirectionDegrees { get; set; } = 0f;

	// ---- Light and haze ----

	/// <summary>0 = full sun. 1 = no direct sunlight reaches the clouds or the scene (thick overcast).</summary>
	[Property, Group( "Light & Haze" ), Range( 0, 1 )] public float SunDimming { get; set; } = 0f;

	/// <summary>Multiplier on cloud ambient light. Below 1 darkens cloud bases and shadowed sides (storms).</summary>
	[Property, Group( "Light & Haze" ), Range( 0, 2 )] public float CloudAmbientScale { get; set; } = 1f;

	/// <summary>Multiplier on haze (Mie scattering in the atmosphere): whiter, hazier sky and more distance fog.</summary>
	[Property, Group( "Light & Haze" ), Range( 0.25f, 8 )] public float Haze { get; set; } = 1f;

	// ---- Rain and lightning (hooks for gameplay and effects) ----

	/// <summary>0 = dry, 1 = downpour. Read it from WeatherSystem.Current to drive rain effects.</summary>
	[Property, Group( "Rain & Lightning" ), Range( 0, 1 )] public float Precipitation { get; set; } = 0f;

	/// <summary>Average lightning strikes per minute. WeatherSystem raises OnLightning for each one.</summary>
	[Property, Group( "Rain & Lightning" ), Range( 0, 60 )] public float LightningPerMinute { get; set; } = 0f;

	// ---- Place in the automatic weather cycle ----

	/// <summary>
	/// Where this weather sits in the automatic cycle (WeatherSystem.AutoCycle).
	/// x = moisture (0 dry, 1 saturated), y = instability (0 stable, 1 explosive convection).
	/// The cycle moves a point through this space and blends the presets nearest to it.
	/// Typical: clear (0.1, 0.15), partly cloudy (0.4, 0.4), towering cumulus (0.6, 0.75),
	/// overcast (0.9, 0.2), storm (0.85, 0.95).
	/// </summary>
	[Property, Group( "Cycle" )] public Vector2 CyclePosition { get; set; } = new Vector2( 0.5f, 0.5f );
}

/// <summary>What the clouds of one layer look like under a given weather.</summary>
public sealed class WeatherLayer
{
	[Property, Range( 0, 1 )] public float Coverage { get; set; } = 0.35f;
	[Property, Range( 0, 2 )] public float Density { get; set; } = 1f;
	[Property, Range( 0, 1 )] public float CloudType { get; set; } = 0.6f;
	[Property, Range( 0, 1 )] public float HeightVariation { get; set; } = 0.85f;
	[Property, Range( 0, 1 )] public float Anvil { get; set; } = 0.5f;

	/// <summary>How tall clouds can grow above the layer bottom, in meters (clamped to the layer). Shallow fair-weather cumulus ~1500, towering cumulus ~5000, storms 12000+.</summary>
	[Property, Range( 100, 20000 )] public float CloudHeightMeters { get; set; } = 20000f;
}

/// <summary>
/// The blended weather actually in effect (a WeatherPreset in plain values).
/// Produced by WeatherSystem, consumed by SkyCloudSystem.
/// </summary>
public sealed class WeatherState
{
	public const int MaxLayers = 8;

	public readonly float[] Coverage = new float[MaxLayers];
	public readonly float[] Density = new float[MaxLayers];
	public readonly float[] CloudType = new float[MaxLayers];
	public readonly float[] HeightVariation = new float[MaxLayers];
	public readonly float[] Anvil = new float[MaxLayers];
	// Meters. Created on first use: added after the others, and a hot reload leaves
	// new initialized fields null on objects that already exist.
	public float[] CloudHeight => _cloudHeight ??= new float[MaxLayers];
	float[] _cloudHeight;
	public int LayerCount;

	public float ExtinctionScale = 1f;
	public float WindSpeed;
	public float WindDirectionDegrees;
	public float SunDimming;
	public float CloudAmbientScale = 1f;
	public float Haze = 1f;
	public float Precipitation;
	public float LightningPerMinute;

	public void CopyFrom( WeatherPreset p )
	{
		LayerCount = Math.Min( p.Layers?.Count ?? 0, MaxLayers );
		for ( int i = 0; i < LayerCount; i++ )
		{
			var l = p.Layers[i] ?? new WeatherLayer();
			Coverage[i] = l.Coverage;
			Density[i] = l.Density;
			CloudType[i] = l.CloudType;
			HeightVariation[i] = l.HeightVariation;
			Anvil[i] = l.Anvil;
			CloudHeight[i] = l.CloudHeightMeters;
		}
		ExtinctionScale = p.ExtinctionScale;
		WindSpeed = p.WindSpeed;
		WindDirectionDegrees = p.WindDirectionDegrees;
		SunDimming = p.SunDimming;
		CloudAmbientScale = p.CloudAmbientScale;
		Haze = p.Haze;
		Precipitation = p.Precipitation;
		LightningPerMinute = p.LightningPerMinute;
	}

	public void CopyFrom( WeatherState s )
	{
		LayerCount = s.LayerCount;
		Array.Copy( s.Coverage, Coverage, MaxLayers );
		Array.Copy( s.Density, Density, MaxLayers );
		Array.Copy( s.CloudType, CloudType, MaxLayers );
		Array.Copy( s.HeightVariation, HeightVariation, MaxLayers );
		Array.Copy( s.Anvil, Anvil, MaxLayers );
		Array.Copy( s.CloudHeight, CloudHeight, MaxLayers );
		ExtinctionScale = s.ExtinctionScale;
		WindSpeed = s.WindSpeed;
		WindDirectionDegrees = s.WindDirectionDegrees;
		SunDimming = s.SunDimming;
		CloudAmbientScale = s.CloudAmbientScale;
		Haze = s.Haze;
		Precipitation = s.Precipitation;
		LightningPerMinute = s.LightningPerMinute;
	}

	/// <summary>this = lerp( a, b, t ). Wind direction takes the short way round.</summary>
	public void Lerp( WeatherState a, WeatherState b, float t )
	{
		LayerCount = Math.Max( a.LayerCount, b.LayerCount );
		for ( int i = 0; i < LayerCount; i++ )
		{
			// A layer missing from one side blends from/to "no clouds".
			bool ha = i < a.LayerCount, hb = i < b.LayerCount;
			Coverage[i] = L( ha ? a.Coverage[i] : 0f, hb ? b.Coverage[i] : 0f, t );
			Density[i] = L( ha ? a.Density[i] : 0f, hb ? b.Density[i] : 0f, t );
			CloudType[i] = L( ha ? a.CloudType[i] : b.CloudType[i], hb ? b.CloudType[i] : a.CloudType[i], t );
			HeightVariation[i] = L( ha ? a.HeightVariation[i] : b.HeightVariation[i], hb ? b.HeightVariation[i] : a.HeightVariation[i], t );
			Anvil[i] = L( ha ? a.Anvil[i] : b.Anvil[i], hb ? b.Anvil[i] : a.Anvil[i], t );
			CloudHeight[i] = L( ha ? a.CloudHeight[i] : b.CloudHeight[i], hb ? b.CloudHeight[i] : a.CloudHeight[i], t );
		}
		ExtinctionScale = L( a.ExtinctionScale, b.ExtinctionScale, t );
		WindSpeed = L( a.WindSpeed, b.WindSpeed, t );
		float d = ((b.WindDirectionDegrees - a.WindDirectionDegrees) % 360f + 540f) % 360f - 180f;
		WindDirectionDegrees = (a.WindDirectionDegrees + d * t + 360f) % 360f;
		SunDimming = L( a.SunDimming, b.SunDimming, t );
		CloudAmbientScale = L( a.CloudAmbientScale, b.CloudAmbientScale, t );
		Haze = L( a.Haze, b.Haze, t );
		Precipitation = L( a.Precipitation, b.Precipitation, t );
		LightningPerMinute = L( a.LightningPerMinute, b.LightningPerMinute, t );
	}

	/// <summary>
	/// this = weighted average of <paramref name="count"/> states (weights need not sum to 1).
	/// Wind direction is averaged as a vector, so 350° and 10° blend to 0°, not 180°.
	/// </summary>
	public void Blend( WeatherState[] states, float[] weights, int count )
	{
		float total = 0f;
		for ( int k = 0; k < count; k++ ) total += weights[k];
		if ( count == 0 || total <= 0f ) return;

		LayerCount = 0;
		for ( int k = 0; k < count; k++ ) LayerCount = Math.Max( LayerCount, states[k].LayerCount );

		for ( int i = 0; i < MaxLayers; i++ )
		{
			Coverage[i] = Density[i] = CloudType[i] = HeightVariation[i] = Anvil[i] = CloudHeight[i] = 0f;
		}
		ExtinctionScale = WindSpeed = SunDimming = CloudAmbientScale = Haze = Precipitation = LightningPerMinute = 0f;
		float wx = 0f, wy = 0f;

		for ( int k = 0; k < count; k++ )
		{
			var s = states[k];
			float w = weights[k] / total;
			for ( int i = 0; i < LayerCount; i++ )
			{
				bool has = i < s.LayerCount;
				// A layer missing from a preset counts as clear, keeping its look neutral.
				Coverage[i] += w * (has ? s.Coverage[i] : 0f);
				Density[i] += w * (has ? s.Density[i] : 0f);
				CloudType[i] += w * (has ? s.CloudType[i] : 0.5f);
				HeightVariation[i] += w * (has ? s.HeightVariation[i] : 0f);
				Anvil[i] += w * (has ? s.Anvil[i] : 0f);
				CloudHeight[i] += w * (has ? s.CloudHeight[i] : 0f);
			}
			ExtinctionScale += w * s.ExtinctionScale;
			WindSpeed += w * s.WindSpeed;
			float rad = s.WindDirectionDegrees * MathF.PI / 180f;
			wx += w * MathF.Cos( rad );
			wy += w * MathF.Sin( rad );
			SunDimming += w * s.SunDimming;
			CloudAmbientScale += w * s.CloudAmbientScale;
			Haze += w * s.Haze;
			Precipitation += w * s.Precipitation;
			LightningPerMinute += w * s.LightningPerMinute;
		}
		WindDirectionDegrees = (MathF.Atan2( wy, wx ) * 180f / MathF.PI + 360f) % 360f;
	}

	static float L( float a, float b, float t ) => a + (b - a) * t;
}
