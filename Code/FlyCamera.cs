using Sandbox;
using System;

// ============================================================================
//  FlyCamera  -  editor-style free camera for play mode
//
//  Put it on the camera's GameObject. Controls match the s&box editor camera:
//    WASD           fly where you look (forward follows pitch)
//    E / Q          straight up / down in world space (Space / Ctrl also work)
//    Mouse wheel    faster / slower (each notch x1.25)
//    Shift / Alt    4x faster / 4x slower while held
//    Mouse          look
//  No collision: this is for flying around and through clouds kilometres up.
// ============================================================================

[Title( "Fly Camera" )]
[Category( "Camera" )]
[Icon( "flight" )]
public sealed class FlyCamera : Component
{
	const float InchToMeter = 0.0254f;

	/// <summary>Base speed in meters per second. The mouse wheel changes it while playing.</summary>
	[Property, Range( 0.5f, 2000f )] public float SpeedMetersPerSecond { get; set; } = 25f;

	/// <summary>Multiplier while the run key (Shift) is held.</summary>
	[Property, Range( 1f, 20f )] public float FastFactor { get; set; } = 4f;

	/// <summary>Multiplier while the walk key (Alt) is held.</summary>
	[Property, Range( 0.01f, 1f )] public float SlowFactor { get; set; } = 0.25f;

	/// <summary>How quickly the camera reaches its target velocity (per second). 0 = instant.</summary>
	[Property, Range( 0f, 30f )] public float Smoothing { get; set; } = 10f;

	/// <summary>Speed change per mouse-wheel notch.</summary>
	[Property, Range( 1.05f, 2f )] public float WheelStep { get; set; } = 1.25f;

	/// <summary>Keeps the view from flipping over the top or bottom.</summary>
	[Property] public bool ClampPitch { get; set; } = true;

	const float MinSpeed = 0.5f;     // m/s
	const float MaxSpeed = 5000f;    // m/s

	Angles _look;
	Vector3 _velocity; // world units per second

	protected override void OnEnabled()
	{
		// Start from wherever the camera is already looking (no snap).
		_look = WorldRotation.Angles();
		_look.roll = 0f;
		_velocity = Vector3.Zero;
	}

	protected override void OnUpdate()
	{
		// ---- Look ----
		_look += Input.AnalogLook;
		if ( ClampPitch )
			_look.pitch = Math.Clamp( _look.pitch, -89f, 89f );
		_look.roll = 0f;
		WorldRotation = _look.ToRotation();

		// ---- Speed (mouse wheel, like the editor camera) ----
		float wheel = Input.MouseWheel.y;
		if ( wheel != 0f )
			SpeedMetersPerSecond = Math.Clamp( SpeedMetersPerSecond * MathF.Pow( WheelStep, wheel ), MinSpeed, MaxSpeed );

		float speed = SpeedMetersPerSecond / InchToMeter; // world units per second
		if ( Input.Down( "Run" ) ) speed *= FastFactor;
		else if ( Input.Down( "Walk" ) ) speed *= SlowFactor;

		// ---- Direction ----
		// AnalogMove: x = forward/back, y = left/right (WASD or the left stick).
		Vector3 move = Input.AnalogMove;
		Vector3 wish = WorldRotation.Forward * move.x + WorldRotation.Left * move.y;

		// Vertical in world space, like the editor's E / Q.
		float up = 0f;
		if ( Input.Keyboard.Down( "e" ) || Input.Down( "Jump" ) ) up += 1f;
		if ( Input.Keyboard.Down( "q" ) || Input.Down( "Duck" ) ) up -= 1f;
		wish += Vector3.Up * up;

		if ( wish.Length > 1f )
			wish = wish.Normal;

		// ---- Move ----
		Vector3 target = wish * speed;
		_velocity = Smoothing <= 0f
			? target
			: Vector3.Lerp( _velocity, target, 1f - MathF.Exp( -Smoothing * Time.Delta ) );

		WorldPosition += _velocity * Time.Delta;
	}
}
