using Sandbox;
using System;
using System.Collections.Generic;

// ============================================================================
//  WeatherSystem  -  Phase 6
//
//  Drives a SkyCloudSystem (SkyCloudSystem.Weather) with a blended WeatherState.
//  Runs in the editor too, so weather can be previewed.
//
//  Two modes:
//   * Manual (AutoCycle off): blends to the Weather preset, or to whatever
//     SetWeather asks for, over TransitionSeconds.
//   * Automatic cycle (AutoCycle on): a small weather simulation. The state is a
//     point (moisture, instability) that drifts toward randomly drawn weather
//     regimes, gets an instability boost in the afternoon and a drop at night
//     (convection follows the sun), and switches to a clearing regime after a
//     storm has lasted a while. The weather shown is a distance-weighted blend
//     of the CyclePresets nearest that point (WeatherPreset.CyclePosition), so it
//     changes continuously and never pops.
//
//  Gameplay:
//    weather.SetWeather( stormPreset, 90f );   // with AutoCycle: steer there, then evolve on
//    weather.Current.Precipitation             // 0..1, drive rain effects from it
//    weather.OnLightning += pos => ...         // one call per lightning strike
// ============================================================================

[Title( "Weather System" )]
[Category( "Sky" )]
[Icon( "thunderstorm" )]
public sealed class WeatherSystem : Component, Component.ExecuteInEditor
{
	/// <summary>The cloud system to drive.</summary>
	[Property] public SkyCloudSystem Clouds { get; set; }

	/// <summary>Weather at start (manual mode). Changing it in the inspector blends to the new preset over TransitionSeconds.</summary>
	[Property] public WeatherPreset Weather { get; set; }

	/// <summary>Blend time used when Weather is changed in the inspector, or when SetWeather is called without a time.</summary>
	[Property, Range( 0, 600 )] public float TransitionSeconds { get; set; } = 60f;

	// ---- Automatic cycle ----

	/// <summary>Let the weather evolve on its own (see the class comment).</summary>
	[Property, Group( "Automatic Cycle" )] public bool AutoCycle { get; set; } = false;

	/// <summary>Presets the cycle blends between, placed by their CyclePosition. Usually clear, partly cloudy, towering cumulus, overcast, storm.</summary>
	[Property, Group( "Automatic Cycle" )] public List<WeatherPreset> CyclePresets { get; set; } = new();

	/// <summary>Weather hours per real minute when the sky's day cycle is stopped (SkyCloudSystem.DayLengthSeconds = 0). With a running day cycle, the weather uses the same clock.</summary>
	[Property, Group( "Automatic Cycle" ), Range( 0.05f, 60f )] public float HoursPerRealMinute { get; set; } = 1f;

	/// <summary>How strongly the time of day drives convection: 0 = none, 1 = clouds build clearly through the afternoon and collapse at night.</summary>
	[Property, Group( "Automatic Cycle" ), Range( 0f, 2f )] public float DiurnalStrength { get; set; } = 1f;

	/// <summary>How often the weather regime changes. 1 = every 4 to 16 hours; 2 = twice as often.</summary>
	[Property, Group( "Automatic Cycle" ), Range( 0.1f, 5f )] public float Changeability { get; set; } = 1f;

	/// <summary>Seed for the cycle's randomness (0 = different every run).</summary>
	[Property, Group( "Automatic Cycle" )] public int Seed { get; set; } = 0;

	/// <summary>Current moisture of the cycle (0 dry, 1 saturated).</summary>
	public float Moisture => _m;

	/// <summary>Current instability including the time-of-day effect (0 stable, 1 explosive).</summary>
	public float Instability => _iEff;

	/// <summary>Name of the weather regime the cycle is heading for.</summary>
	public string RegimeName => _regimeName;

	/// <summary>Weather hours until the cycle draws a new regime.</summary>
	public float HoursUntilRegimeChange => _regimeHoursLeft;

	// ---- State ----

	/// <summary>The blended weather in effect right now.</summary>
	public WeatherState Current => _current ??= new WeatherState();

	/// <summary>The preset being blended towards (manual mode), or the one SetWeather steered to.</summary>
	public WeatherPreset Target { get; private set; }

	/// <summary>0 at the start of a transition, 1 once the target weather is reached.</summary>
	public float TransitionProgress => _duration <= 0f ? 1f : Math.Clamp( _elapsed / _duration, 0f, 1f );

	/// <summary>Raised for each lightning strike, with a rough world position in the cloud layer near the camera.</summary>
	public event Action<Vector3> OnLightning;

	// Created on first use, not by field initializers: a hot reload can leave
	// initialized fields null on an existing component.
	WeatherState _current, _fromState, _toState;
	WeatherState _from => _fromState ??= new WeatherState();
	WeatherState _to => _toState ??= new WeatherState();
	float _elapsed, _duration;
	bool _initialized;
	bool _suppressInspectorChange;

	// Cycle state
	float _m = 0.3f, _i = 0.3f, _iEff = 0.3f;          // moisture, base instability, instability incl. time of day
	float _regimeM = 0.3f, _regimeI = 0.3f, _regimeHoursLeft;
	string _regimeName = "fair";
	float _stormHours, _stormLimitHours = 2f;
	float _steerFromM, _steerFromI, _steerToM, _steerToI, _steerElapsed, _steerDuration; // SetWeather in cycle mode
	Random _rng;
	WeatherState[] _cycleStates = Array.Empty<WeatherState>();
	float[] _cycleWeights = Array.Empty<float>();

	/// <summary>
	/// Change the weather to <paramref name="preset"/> over <paramref name="seconds"/>
	/// (negative = TransitionSeconds).
	/// Manual mode: blends from the weather as it is right now, so nothing jumps.
	/// AutoCycle: steers the cycle to the preset's CyclePosition, holds it there for a
	/// few hours, then lets the weather evolve on from it.
	/// </summary>
	public void SetWeather( WeatherPreset preset, float seconds = -1f )
	{
		if ( preset is null )
			return;
		float dur = seconds < 0f ? TransitionSeconds : seconds;

		if ( AutoCycle )
		{
			EnsureRng();
			_steerFromM = _m; _steerFromI = _i;
			_steerToM = preset.CyclePosition.x; _steerToI = preset.CyclePosition.y;
			_steerElapsed = 0f;
			_steerDuration = Math.Max( dur, 0.001f );
			SetRegime( "requested", _steerToM, _steerToI, Lerp( 2f, 6f, (float)_rng.NextDouble() ) );
			Target = preset;
			return;
		}

		if ( !_initialized )
		{
			Current.CopyFrom( preset );
			_initialized = true;
		}

		_from.CopyFrom( Current );
		_to.CopyFrom( preset );
		Target = preset;
		_elapsed = 0f;
		_duration = dur;

		// Keep the inspector field in sync without restarting the blend.
		if ( Weather != preset )
		{
			_suppressInspectorChange = true;
			Weather = preset;
		}
	}

	protected override void OnEnabled()
	{
		_initialized = false;
		_rng = null;
		if ( Weather is not null )
		{
			Current.CopyFrom( Weather );
			_from.CopyFrom( Current );
			_to.CopyFrom( Current );
			Target = Weather;
			_elapsed = _duration = 0f;
			_initialized = true;

			// Start the cycle where the starting preset sits.
			_m = _regimeM = Weather.CyclePosition.x;
			_i = _regimeI = Weather.CyclePosition.y;
		}
		_regimeHoursLeft = 0f; // draw a regime on the first cycle update
	}

	protected override void OnDisabled()
	{
		if ( Clouds is not null && Clouds.Weather == Current )
			Clouds.Weather = null;
	}

	protected override void OnUpdate()
	{
		bool cycling = AutoCycle && HasCyclePresets();

		if ( cycling )
		{
			UpdateCycle();
			_initialized = true;
		}
		else
		{
			// The inspector field was changed by hand: blend to it.
			if ( Weather != Target )
			{
				if ( _suppressInspectorChange )
					_suppressInspectorChange = false;
				else if ( Weather is not null )
					SetWeather( Weather );
			}

			if ( !_initialized )
			{
				if ( Clouds is not null && Clouds.Weather == Current )
					Clouds.Weather = null;
				return;
			}

			// Re-read the target preset every frame, so editing it in the inspector
			// shows up immediately (cheap: a few dozen floats).
			if ( Target is not null )
				_to.CopyFrom( Target );

			// Blend. A smoothstep ease so transitions start and finish gently.
			if ( _elapsed < _duration )
				_elapsed += Time.Delta;
			float t = TransitionProgress;
			t = t * t * (3f - 2f * t);
			Current.Lerp( _from, _to, t );
		}

		if ( Clouds is not null )
			Clouds.Weather = Current;

		// Lightning: a Poisson process at LightningPerMinute.
		if ( Game.IsPlaying && Current.LightningPerMinute > 0f )
		{
			float chance = 1f - MathF.Exp( -Current.LightningPerMinute / 60f * Time.Delta );
			EnsureRng();
			if ( _rng.NextDouble() < chance )
				OnLightning?.Invoke( LightningPosition() );
		}
	}

	// ---- Automatic cycle -----------------------------------------------------------

	bool HasCyclePresets()
	{
		if ( CyclePresets is null ) return false;
		foreach ( var p in CyclePresets )
			if ( p is not null ) return true;
		return false;
	}

	void EnsureRng()
	{
		_rng ??= Seed != 0 ? new Random( Seed ) : new Random();
	}

	/// <summary>Weather hours that passed this frame.</summary>
	float WeatherHours()
	{
		float day = Clouds?.DayLengthSeconds ?? 0f;
		float hoursPerSecond = day > 0.01f ? 24f / day : HoursPerRealMinute / 60f;
		return Time.Delta * hoursPerSecond;
	}

	void UpdateCycle()
	{
		EnsureRng();
		float dh = WeatherHours();

		// ---- Regime: what the weather is heading for ----
		_regimeHoursLeft -= dh;
		if ( _regimeHoursLeft <= 0f )
			DrawRegime();

		// ---- Drift toward the regime, with a little wander ----
		// Moisture changes over ~3 h, instability over ~2 h. The wander is a
		// mean-reverting random walk (scaled by sqrt(time) so it does not depend on frame rate).
		float wander = 0.05f * MathF.Sqrt( MathF.Max( dh, 0f ) );
		_m += (_regimeM - _m) * (1f - MathF.Exp( -dh / 3f )) + Noise() * wander;
		_i += (_regimeI - _i) * (1f - MathF.Exp( -dh / 2f )) + Noise() * wander;

		// ---- SetWeather in cycle mode: steer there over the requested time ----
		if ( _steerElapsed < _steerDuration )
		{
			_steerElapsed += Time.Delta;
			float s = Math.Clamp( _steerElapsed / _steerDuration, 0f, 1f );
			s = s * s * (3f - 2f * s);
			_m = Lerp( _steerFromM, _steerToM, s );
			_i = Lerp( _steerFromI, _steerToI, s );
		}

		_m = Math.Clamp( _m, 0f, 1f );
		_i = Math.Clamp( _i, 0f, 1f );

		// ---- Time of day: the sun drives convection ----
		// Peaks around 15:00, lowest around 03:00, scaled by moisture
		// (dry air does not build towers however warm the afternoon is).
		// Convective regimes have only moderate base instability, so their towers
		// and storms come from this afternoon heating and collapse at night (a
		// first version with a high base let convection peak overnight).
		float hour = Clouds?.TimeOfDay ?? 12f;
		float diurnal = MathF.Cos( (hour - 15f) / 24f * MathF.PI * 2f );
		_iEff = Math.Clamp( _i + DiurnalStrength * 0.35f * diurnal * Math.Clamp( _m * 1.5f, 0f, 1f ), 0f, 1f );

		// ---- Storms burn out: after a while in storm conditions, clear up ----
		bool storming = _m > 0.7f && _iEff > 0.75f;
		_stormHours = storming ? _stormHours + dh : MathF.Max( _stormHours - dh, 0f );
		if ( _stormHours > _stormLimitHours && _regimeName != "clearing" )
		{
			SetRegime( "clearing", Lerp( 0.3f, 0.5f, R() ), Lerp( 0.1f, 0.3f, R() ), Lerp( 6f, 12f, R() ) / Changeability );
			_stormHours = 0f;
		}

		// ---- Blend the presets nearest (moisture, instability) ----
		BlendCycle( _m, _iEff );
	}

	void DrawRegime()
	{
		// A rough climate: mostly fair weather, sometimes humid and convective,
		// sometimes a frontal overcast spell, occasionally a stormy spell.
		float r = R();
		float hours = Lerp( 4f, 16f, R() ) / Changeability;
		// Instability here is the BASE; the afternoon adds up to +0.35, night removes as much.
		if ( r < 0.45f ) SetRegime( "fair", Lerp( 0.1f, 0.45f, R() ), Lerp( 0.15f, 0.35f, R() ), hours );
		else if ( r < 0.70f ) SetRegime( "convective", Lerp( 0.55f, 0.8f, R() ), Lerp( 0.4f, 0.6f, R() ), hours );
		else if ( r < 0.90f ) SetRegime( "frontal", Lerp( 0.8f, 1.0f, R() ), Lerp( 0.1f, 0.35f, R() ), hours );
		else SetRegime( "stormy", Lerp( 0.75f, 0.95f, R() ), Lerp( 0.7f, 0.9f, R() ), hours );
	}

	void SetRegime( string name, float m, float i, float hours )
	{
		_regimeName = name;
		_regimeM = m;
		_regimeI = i;
		_regimeHoursLeft = hours;
		_stormLimitHours = Lerp( 1f, 3f, R() );
	}

	void BlendCycle( float m, float i )
	{
		int n = CyclePresets.Count;
		// Null check too: after a hot reload, fields added by new code start out null
		// on an existing component (their initializers do not run).
		if ( _cycleStates is null || _cycleWeights is null || _cycleStates.Length != n )
		{
			_cycleStates = new WeatherState[n];
			for ( int k = 0; k < n; k++ ) _cycleStates[k] = new WeatherState();
			_cycleWeights = new float[n];
		}

		int count = 0;
		for ( int k = 0; k < n; k++ )
		{
			var p = CyclePresets[k];
			if ( p is null ) continue;
			_cycleStates[count].CopyFrom( p ); // re-read every frame: inspector edits show up live
			float dx = m - p.CyclePosition.x, dy = i - p.CyclePosition.y;
			float d2 = dx * dx + dy * dy;
			// Inverse distance weights (power 4): close presets dominate, but the
			// result changes continuously as the point moves.
			_cycleWeights[count] = 1f / ((d2 + 0.0004f) * (d2 + 0.0004f));
			count++;
		}
		Current.Blend( _cycleStates, _cycleWeights, count );
	}

	float R() => (float)_rng.NextDouble();
	float Noise() => R() * 2f - 1f;
	static float Lerp( float a, float b, float t ) => a + (b - a) * t;

	/// <summary>A random point in the lowest cloud layer within ~10 km of the camera.</summary>
	Vector3 LightningPosition()
	{
		var cam = Scene?.Camera?.WorldPosition ?? WorldPosition;
		float angle = R() * MathF.PI * 2f;
		float dist = 10000f / 0.0254f * MathF.Sqrt( R() );
		float altM = 1500f;
		if ( Clouds?.Layers is { Count: > 0 } layers && layers[0] is not null )
			altM = (layers[0].BottomMeters + layers[0].TopMeters) * 0.5f;
		float z = (Clouds?.GroundLevel ?? 0f) + altM / 0.0254f;
		return new Vector3( cam.x + MathF.Cos( angle ) * dist, cam.y + MathF.Sin( angle ) * dist, z );
	}
}
