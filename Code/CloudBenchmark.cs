using Sandbox;
using Sandbox.Diagnostics;
using System;
using System.Collections.Generic;
using System.Linq;

// ============================================================================
//  CloudBenchmark  -  Phase 5 baseline measurement
//
//  Put it on any GameObject in the scene and enter play mode. It:
//    * pins the camera to a fixed pose (the camera's pose at start, or the
//      Position / Angles properties),
//    * freezes time of day and wind (and resets the wind offsets),
//    * runs passes Off, Low, Medium, High, Ultra (plus an optional breakdown
//      at High: sky only, no aerial perspective, clouds only): warm up, then
//      sample the GPU frame time every frame,
//    * logs a table. Cost = pass GPU time - Off GPU time.
//
//  Changes happen on the play-mode scene only; nothing is saved.
//
//  API CHECK: Sandbox.Diagnostics.PerformanceStats.GpuFrametime / GpuFrameNumber
//  (static), Screen.Size.
// ============================================================================

public sealed class CloudBenchmark : Component
{
	/// <summary>The cloud system to measure. Its GameObject must hold the rendering camera.</summary>
	[Property] public SkyCloudSystem Clouds { get; set; }

	/// <summary>Optional: a camera controller (e.g. the fly cam) to disable during the run so the pose stays fixed.</summary>
	[Property] public Component DisableDuringRun { get; set; }

	/// <summary>On: use the camera's pose when play starts. Off: use Position and Angles below.</summary>
	[Property] public bool UseStartPose { get; set; } = true;
	[Property] public Vector3 Position { get; set; }
	[Property] public Angles Angles { get; set; }

	[Property, Range( 0, 24 )] public float TimeOfDay { get; set; } = 10f;
	[Property, Range( 0.5f, 10 )] public float WarmupSeconds { get; set; } = 3f;
	[Property, Range( 1, 30 )] public float SampleSeconds { get; set; } = 6f;

	[Property] public bool IncludeOffPass { get; set; } = true;

	/// <summary>Extra passes at High quality that split the cost into sky, aerial perspective and clouds.</summary>
	[Property] public bool IncludeBreakdown { get; set; } = true;
	[Property] public bool RunOnStart { get; set; } = true;

	// ---- Run state ----

	/// <summary>One pass: a quality tier (null = component off) and optional feature switches.</summary>
	record struct Pass( string Name, CloudQuality? Quality, bool Clouds = true, bool Sky = true, bool Aerial = true );

	readonly List<Pass> _passes = new();

	// Settings restored between and after passes.
	readonly List<bool> _layerEnabled = new();
	bool _replaceSky;
	float _aerial;
	readonly List<float> _gpu = new();
	readonly List<float> _cpu = new();
	readonly List<string> _results = new();

	int _pass = -1;
	float _passStart;
	bool _sampling;
	long _lastGpuFrame = -1;
	float? _offGpu;

	public bool Running => _pass >= 0 && _pass < _passes.Count;

	protected override void OnStart()
	{
		if ( RunOnStart )
			StartRun();
	}

	public void StartRun()
	{
		if ( Clouds is null )
		{
			Log.Warning( "CloudBenchmark: no Clouds assigned." );
			return;
		}

		var cam = Clouds.GameObject;
		if ( UseStartPose )
		{
			Position = cam.WorldPosition;
			Angles = cam.WorldRotation.Angles();
		}

		if ( DisableDuringRun is not null )
			DisableDuringRun.Enabled = false;

		// Freeze everything that changes the image over time.
		Clouds.DayLengthSeconds = 0f;
		Clouds.TimeOfDay = TimeOfDay;
		foreach ( var layer in Clouds.Layers )
		{
			if ( layer is null ) continue;
			layer.WindSpeed = 0f;
			layer.WindOffset = Vector2.Zero;
		}

		_layerEnabled.Clear();
		foreach ( var layer in Clouds.Layers )
			_layerEnabled.Add( layer?.Enabled ?? false );
		_replaceSky = Clouds.ReplaceSky;
		_aerial = Clouds.AerialPerspective;

		_passes.Clear();
		if ( IncludeOffPass ) _passes.Add( new Pass( "Off", null ) );
		foreach ( CloudQuality q in Enum.GetValues( typeof( CloudQuality ) ) )
			_passes.Add( new Pass( q.ToString(), q ) );
		if ( IncludeBreakdown )
		{
			_passes.Add( new Pass( "High sky only", CloudQuality.High, Clouds: false ) );
			_passes.Add( new Pass( "High no aerial", CloudQuality.High, Aerial: false ) );
			_passes.Add( new Pass( "High clouds only", CloudQuality.High, Sky: false, Aerial: false ) );
		}

		_results.Clear();
		_offGpu = null;

		Log.Info( $"CloudBenchmark: start. pos=({Position.x:0.0}, {Position.y:0.0}, {Position.z:0.0}) " +
			$"angles=({Angles.pitch:0.0}, {Angles.yaw:0.0}, {Angles.roll:0.0}) time={TimeOfDay:0.0} " +
			$"layers={Clouds.Layers.Count(l => l is not null && l.Enabled)}" );

		BeginPass( 0 );
	}

	void BeginPass( int index )
	{
		_pass = index;
		_passStart = RealTime.Now;
		_sampling = false;
		_gpu.Clear();
		_cpu.Clear();

		if ( !Running )
		{
			Finish();
			return;
		}

		var pass = _passes[_pass];
		if ( pass.Quality is null )
		{
			Clouds.Enabled = false;
			return;
		}

		Clouds.Quality = pass.Quality.Value; // re-bakes the noise if the size changes (inside warmup)
		ApplySwitches( pass.Clouds, pass.Sky, pass.Aerial );
		Clouds.Enabled = true;
	}

	/// <summary>Turns features off for a pass; true restores the original setting.</summary>
	void ApplySwitches( bool clouds, bool sky, bool aerial )
	{
		for ( int i = 0; i < Clouds.Layers.Count && i < _layerEnabled.Count; i++ )
		{
			if ( Clouds.Layers[i] is not null )
				Clouds.Layers[i].Enabled = clouds && _layerEnabled[i];
		}
		Clouds.ReplaceSky = sky && _replaceSky;
		Clouds.AerialPerspective = aerial ? _aerial : 0f;
	}

	protected override void OnUpdate()
	{
		if ( !Running )
			return;

		// Hold the pose every frame.
		var cam = Clouds.GameObject;
		cam.WorldPosition = Position;
		cam.WorldRotation = Angles.ToRotation();

		float elapsed = RealTime.Now - _passStart;

		if ( !_sampling )
		{
			if ( elapsed >= WarmupSeconds )
			{
				_sampling = true;
				_passStart = RealTime.Now;
			}
			return;
		}

		// GPU time arrives a few frames late; take each reported frame once.
		long gpuFrame = (long)PerformanceStats.GpuFrameNumber;
		if ( gpuFrame != _lastGpuFrame )
		{
			_lastGpuFrame = gpuFrame;
			_gpu.Add( (float)PerformanceStats.GpuFrametime );
		}
		_cpu.Add( (float)(PerformanceStats.FrameTime * 1000.0) );

		if ( elapsed >= SampleSeconds )
		{
			RecordPass();
			BeginPass( _pass + 1 );
		}
	}

	void RecordPass()
	{
		var name = _passes[_pass].Name;
		if ( _gpu.Count == 0 )
		{
			_results.Add( $"{name,-16} no GPU samples" );
			return;
		}

		var sorted = _gpu.OrderBy( x => x ).ToList();
		float avg = _gpu.Average();
		float med = sorted[sorted.Count / 2];
		float p95 = sorted[Math.Min( sorted.Count - 1, (int)(sorted.Count * 0.95f) )];
		float cpu = _cpu.Count > 0 ? _cpu.Average() : 0f;

		if ( _passes[_pass].Quality is null )
			_offGpu = med;

		string cost = _offGpu is null || _passes[_pass].Quality is null ? "" : $"   cost {med - _offGpu.Value,6:0.00} ms";
		string steps = _passes[_pass].Quality is null ? "" : $"   steps {Clouds.ViewSteps}";
		_results.Add( $"{name,-16} GPU avg {avg,6:0.00}  med {med,6:0.00}  p95 {p95,6:0.00}   CPU frame {cpu,6:0.00} ms   n={_gpu.Count}{cost}{steps}" );
	}

	void Finish()
	{
		_pass = -1;
		ApplySwitches( true, true, true );
		Clouds.Enabled = true;
		if ( DisableDuringRun is not null )
			DisableDuringRun.Enabled = true;

		// Screen.Size is read here, not at start: at play start it can still report a stale size.
		Log.Info( $"CloudBenchmark: results at {Screen.Size.x}x{Screen.Size.y}, resolution={Clouds.Resolution}, temporal={Clouds.Temporal}, stepsOverride={Clouds.ViewStepsOverride} (GPU ms; cost = median minus Off median)\n" + string.Join( "\n", _results ) );
	}
}
