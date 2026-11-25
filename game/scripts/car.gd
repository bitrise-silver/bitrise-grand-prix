extends RigidBody3D
## The player's RC car.
##
## The body is a frictionless sphere with locked rotation; the engine handles gravity, ramps,
## jumps and collisions, and this script decides the velocity along the ground each physics
## tick (throttle, grip, steering). That keeps the handling arcade-simple and predictable on
## a phone while still being real physics where it is fun: ramps and walls.

signal effect_applied(kind: String)
## Hit something solid (Armco, a wall, the gantry). `strength` is the speed lost, in m/s.
signal bumped(strength: float)
## Back on the ground after a jump; `air_time` in seconds.
signal landed(air_time: float)

const CarVisual := preload("res://scripts/car_visual.gd")
const CarFx := preload("res://scripts/car_fx.gd")

const RADIUS := 0.6
const MAX_SPEED := 26.0           # units per second on the road
const ACCELERATION := 34.0
const BRAKING := 55.0
const REVERSE_SPEED := 9.0
const COAST_DECELERATION := 9.0
const TURN_RATE := 2.7            # radians per second at full lock
const GRIP := 8.0                 # how quickly sideways sliding dies out
const GRASS_SPEED_FACTOR := 0.38
const BOOST_FACTOR := 1.5         # +50 % for one second
const SLOW_FACTOR := 0.5          # -50 % for one second
const EFFECT_SECONDS := 1.0
## How far the body swings out of line in a hard corner, like a drift, in radians.
const DRIFT_ANGLE := 0.24
## Losing this much speed in one physics tick, without braking for it, counts as a bump.
const BUMP_SPEED := 4.5

## Driving direction in the XZ plane: forward is (cos(heading), 0, sin(heading)).
var heading := 0.0
## -1 (left) to 1 (right).
var steer_input := 0.0
## -1 (brake / reverse) to 1 (full throttle).
var throttle_input := 0.0
var controls_locked := true
## The track node; asked whether the car is on the road.
var track: Node3D
var color := Color("#9247c2")

## 0 none, 1 boosted, 2 slowed.
var effect := 0
var grounded := false
var on_road := true
var forward_speed := 0.0
## How fast the heading is changing, in radians per second.
var turn_rate := 0.0
## Skid marks and dust; false on slow devices.
var effects_enabled := true:
	set(value):
		effects_enabled = value
		if _fx:
			_fx.marks_enabled = value

var _effect_left := 0.0
var _kick := ""
var _pending_reset: Variant = null
var _visual: Node3D
var _ray: RayCast3D
var _shadow: MeshInstance3D
var _fx: CarFx
var _pitch := 0.0
var _slip := 0.0
## The ground velocity set last tick: a sudden drop against it means we hit something.
var _last_planar := Vector2.ZERO
var _bump := 0.0
var _air_time := 0.0
## Where the car is drawn and which way it points. Physics moves the car 60 times a second,
## 0.4 m a step at full speed; drawn as is, it judders against the smoothly following camera,
## worst on 120 Hz screens. So it is drawn between its last two physics positions instead.
var render_position := Vector3.ZERO
var render_heading := 0.0
var _tick_positions: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _tick_headings: Array[float] = [0.0, 0.0]
## Ticks left in which not to glide (right after a reset, so the car does not sweep across the map).
var _snap_ticks := 2


func _ready() -> void:
	mass = 1.0
	can_sleep = false
	continuous_cd = true
	axis_lock_angular_x = true
	axis_lock_angular_y = true
	axis_lock_angular_z = true
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	var surface := PhysicsMaterial.new()
	surface.friction = 0.0
	surface.bounce = 0.05
	physics_material_override = surface

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = RADIUS
	shape.shape = sphere
	add_child(shape)

	_ray = RayCast3D.new()
	_ray.target_position = Vector3(0, -(RADIUS + 0.4), 0)
	add_child(_ray)

	_visual = CarVisual.new()
	_visual.color = color
	# Placed every frame at the drawn position (see render_position), not carried by the body.
	_visual.top_level = true
	add_child(_visual)

	_fx = CarFx.new()
	_fx.marks_enabled = effects_enabled
	add_child(_fx)

	# A soft contact shadow under the car, on top of the real one from the sun: it keeps the
	# car grounded when the shadow map is coarse, and shows how high a jump is.
	var quad := QuadMesh.new()
	quad.size = Vector2(2.7, 1.5)
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0, 0, 0, 0.32))
	gradient.set_color(1, Color(0, 0, 0, 0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	var shadow_material := StandardMaterial3D.new()
	shadow_material.albedo_texture = texture
	shadow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shadow = MeshInstance3D.new()
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shadow.mesh = quad
	_shadow.material_override = shadow_material
	_shadow.top_level = true
	add_child(_shadow)


## Puts the car on the ground at `at`, stopped and pointing along `new_heading`.
func reset_to(at: Vector3, new_heading: float) -> void:
	_pending_reset = {"position": at + Vector3(0, RADIUS + 0.02, 0), "heading": new_heading}
	_snap_ticks = 2
	effect = 0
	_effect_left = 0.0
	_kick = ""
	_slip = 0.0
	_bump = 0.0
	_air_time = 0.0
	if _fx:
		_fx.clear_marks()


func forward() -> Vector3:
	return Vector3(cos(heading), 0, sin(heading))


## Called by pickups: "boost" or "obstacle".
func apply_effect(kind: String) -> void:
	effect = 1 if kind == "boost" else 2
	_effect_left = EFFECT_SECONDS
	_kick = kind
	effect_applied.emit(kind)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _pending_reset != null:
		heading = _pending_reset.heading
		state.transform = Transform3D(Basis.IDENTITY, _pending_reset.position)
		state.linear_velocity = Vector3.ZERO
		forward_speed = 0.0
		_last_planar = Vector2.ZERO
		_pending_reset = null
		return

	var dt := state.step
	if _effect_left > 0.0:
		_effect_left -= dt
		if _effect_left <= 0.0:
			effect = 0

	_ray.force_raycast_update()
	grounded = _ray.is_colliding()
	on_road = track == null or track.call("is_on_road", state.transform.origin)

	var steer := 0.0 if controls_locked else clampf(steer_input, -1.0, 1.0)
	var throttle := 0.0 if controls_locked else clampf(throttle_input, -1.0, 1.0)

	var velocity := state.linear_velocity
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	var lost := _last_planar.length() - ground_speed
	if lost > BUMP_SPEED:
		_bump = maxf(_bump, lost)
	var fwd := forward()
	var right := Vector3(-fwd.z, 0, fwd.x)
	var speed := velocity.dot(fwd)
	var slide := velocity.dot(right)

	var factor := 1.0
	if effect == 1:
		factor = BOOST_FACTOR
	elif effect == 2:
		factor = SLOW_FACTOR
	if grounded and not on_road:
		factor *= GRASS_SPEED_FACTOR
	var top_speed := MAX_SPEED * factor

	if _kick == "boost":
		speed = minf(maxf(speed, 0.0) * BOOST_FACTOR + 2.0, MAX_SPEED * BOOST_FACTOR)
	elif _kick == "obstacle":
		speed *= SLOW_FACTOR
	_kick = ""

	if grounded:
		if throttle > 0.0:
			# Acceleration tapers off towards the top speed.
			speed += ACCELERATION * throttle * clampf(1.0 - speed / top_speed, 0.0, 1.0) * dt
		elif throttle < 0.0:
			if speed > 0.5:
				speed = maxf(0.0, speed + BRAKING * throttle * dt)
			else:
				speed = move_toward(speed, -REVERSE_SPEED * factor, ACCELERATION * 0.5 * -throttle * dt)
		else:
			speed = move_toward(speed, 0.0, COAST_DECELERATION * dt)
		# Above the limit (boost ran out, drove onto grass, hit a bug): bleed the excess off.
		if speed > top_speed:
			speed = lerpf(speed, top_speed, 1.0 - exp(-5.0 * dt))
		slide *= exp(-GRIP * dt)

	# Steering needs some speed to bite, and reverses with the car. Almost none in the air.
	var bite := clampf(absf(speed) / 7.0, 0.0, 1.0) * signf(speed)
	turn_rate = steer * TURN_RATE * bite * (1.0 if grounded else 0.25)
	heading = wrapf(heading + turn_rate * dt, -PI, PI)

	fwd = forward()
	right = Vector3(-fwd.z, 0, fwd.x)
	var planar := fwd * speed + right * slide
	state.linear_velocity = Vector3(planar.x, velocity.y, planar.z)
	forward_speed = speed
	_last_planar = Vector2(planar.x, planar.z)


func _physics_process(_delta: float) -> void:
	# The physics position here is the one after the previous step.
	_tick_positions = [_tick_positions[1], global_position]
	_tick_headings = [_tick_headings[1], heading]
	if _snap_ticks > 0:
		_snap_ticks -= 1
		_tick_positions[0] = global_position
		_tick_headings[0] = heading


func _process(delta: float) -> void:
	var between := Engine.get_physics_interpolation_fraction()
	render_position = _tick_positions[0].lerp(_tick_positions[1], between)
	render_heading = lerp_angle(_tick_headings[0], _tick_headings[1], between)

	# Nose follows the slope on ramps and the arc in the air.
	var target_pitch := 0.0
	if absf(forward_speed) > 2.0:
		target_pitch = clampf(atan2(linear_velocity.y, absf(forward_speed)), -0.6, 0.6)
	_pitch = lerpf(_pitch, target_pitch, 1.0 - exp(-12.0 * delta))
	# Cornering hard on the road, the tail steps out: the body points further into the turn
	# than the car is going. Purely for show; the physics stay grippy and predictable.
	var corner := clampf(turn_rate * forward_speed / 55.0, -1.0, 1.0)
	var target_slip := corner * DRIFT_ANGLE if grounded and on_road and forward_speed > 8.0 else 0.0
	_slip = lerpf(_slip, target_slip, 1.0 - exp(-5.0 * delta))
	_visual.global_transform = Transform3D(Basis.from_euler(Vector3(0, -(render_heading + _slip), _pitch)),
		render_position + Vector3(0, -RADIUS, 0))
	_visual.call("set_steer", 0.0 if controls_locked else steer_input)
	_visual.call("set_lean", corner if grounded else 0.0)
	_visual.call("set_effect", effect)
	_visual.call("set_wheel_speed", forward_speed)

	if _bump > 0.0:
		bumped.emit(_bump)
		_bump = 0.0

	var ground_y := 0.0
	if _ray.is_colliding():
		ground_y = _ray.get_collision_point().y
	var height := maxf(0.0, global_position.y - RADIUS - ground_y)
	_shadow.global_position = Vector3(render_position.x, ground_y + 0.1, render_position.z)
	_shadow.global_rotation = Vector3(-PI * 0.5, -render_heading, 0)
	_shadow.scale = Vector3.ONE * clampf(1.0 - height * 0.08, 0.45, 1.0)

	if height > 0.3 or not grounded:
		_air_time += delta
	else:
		if _air_time > 0.3:
			landed.emit(_air_time)
		_air_time = 0.0

	var throttle := 0.0 if controls_locked else throttle_input
	var contact := Vector3(global_position.x, ground_y, global_position.z)
	# Marks come off the wheels where they are drawn, so a drifting tail leaves a wider arc.
	_fx.feed(contact, heading + _slip, forward_speed, turn_rate, throttle, on_road, grounded and height < 0.3, effect, delta)


## 0 to 1: how loudly the tyres are squealing.
func skid_level() -> float:
	return _fx.skid_level if _fx else 0.0
