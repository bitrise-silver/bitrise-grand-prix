extends Node3D
## What a car leaves behind: tyre marks and smoke when it corners hard, brakes or spins its
## wheels on the road, dust and ruts on grass and sand, a dust cloud when it lands a jump, and
## cyan sparks while boosted. Fed once a frame by whoever moves the car; lives in world space.

## How hard a corner has to be (speed x turn rate, in m/s²) before the tyres start to complain.
const SKID_LATERAL := 30.0
const MARK_COUNT := 1400
const MARK_STEP := 0.35
const MARK_Y := 0.09
const REAR_AXLE := 0.72
const TRACK_HALF := 0.4

## Skid marks, smoke and dust can be turned off where frame rate matters more.
var marks_enabled := true

var _marks: MultiMesh
var _mark_next := 0
var _last_mark: Array = [null, null]
var _smoke: CPUParticles3D
var _dust: CPUParticles3D
var _sparks: CPUParticles3D
var _burst: CPUParticles3D
var _air_time := 0.0


func _ready() -> void:
	top_level = true

	_marks = MultiMesh.new()
	_marks.transform_format = MultiMesh.TRANSFORM_3D
	_marks.use_colors = true
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	_marks.mesh = plane
	_marks.instance_count = MARK_COUNT
	_marks.visible_instance_count = 0
	var mark_material := StandardMaterial3D.new()
	mark_material.vertex_color_use_as_albedo = true
	mark_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mark_material.albedo_color = Color.WHITE
	var marks_instance := MultiMeshInstance3D.new()
	marks_instance.multimesh = _marks
	marks_instance.material_override = mark_material
	marks_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(marks_instance)

	_smoke = _puffs(Color(0.93, 0.92, 0.96, 0.5), 40, 1.1, Vector2(0.7, 2.6), 1.2)
	_dust = _puffs(Color(0.78, 0.64, 0.45, 0.55), 36, 0.8, Vector2(0.8, 2.4), 0.4)
	_sparks = _puffs(Color(0.25, 1.0, 0.9, 0.9), 30, 0.35, Vector2(0.35, 0.05), 0.0)
	_burst = _puffs(Color(0.78, 0.64, 0.45, 0.6), 26, 0.9, Vector2(1.0, 3.2), 0.3)
	_burst.one_shot = true
	_burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_burst.explosiveness = 0.95
	_burst.initial_velocity_min = 3.0
	_burst.initial_velocity_max = 6.0
	_burst.spread = 85.0
	_burst.direction = Vector3.UP
	_burst.emission_sphere_radius = 0.9


## `contact` is the point on the ground under the car's centre. `turn_rate` is in radians per
## second, `effect` 0 none, 1 boosted, 2 slowed.
func feed(contact: Vector3, heading: float, speed: float, turn_rate: float, throttle: float,
		on_road: bool, grounded: bool, effect: int, delta: float) -> void:
	var forward := Vector3(cos(heading), 0, sin(heading))
	var right := Vector3(-forward.z, 0, forward.x)
	var rear := contact - forward * REAR_AXLE

	if not grounded:
		_air_time += delta
	elif _air_time > 0.3:
		_burst.global_position = contact + Vector3(0, 0.3, 0)
		_burst.visible = true
		_burst.restart()
		_air_time = 0.0
	else:
		_air_time = 0.0

	var moving := absf(speed) > 1.5
	var lateral := absf(speed * turn_rate)
	var launching := throttle > 0.5 and speed > 0.3 and speed < 8.0
	var braking := throttle < -0.5 and speed > 9.0
	var skidding := grounded and on_road and moving and (lateral > SKID_LATERAL or braking or launching)
	var rutting := grounded and not on_road and absf(speed) > 3.0

	_place(_smoke, rear, heading, skidding and marks_enabled)
	_place(_dust, rear, heading, rutting and marks_enabled)
	_place(_sparks, rear + Vector3(0, 0.3, 0), heading, effect == 1 and moving)

	if not marks_enabled:
		return
	var leaving := skidding or rutting
	var strength := 0.5
	if skidding:
		strength = clampf(0.35 + (lateral - SKID_LATERAL) / 40.0, 0.35, 0.75) if lateral > SKID_LATERAL else 0.45
	var tint := Color(0.08, 0.06, 0.1, strength) if skidding else Color(0.33, 0.24, 0.14, 0.4)
	for side in 2:
		var wheel := rear + right * (TRACK_HALF if side == 0 else -TRACK_HALF)
		wheel.y = contact.y + MARK_Y
		if not leaving:
			_last_mark[side] = null
			continue
		if _last_mark[side] == null:
			_last_mark[side] = wheel
			continue
		var from: Vector3 = _last_mark[side]
		if from.distance_to(wheel) < MARK_STEP:
			continue
		if from.distance_to(wheel) > 3.0:
			_last_mark[side] = wheel
			continue
		_add_mark(from, wheel, tint)
		_last_mark[side] = wheel


func clear_marks() -> void:
	_marks.visible_instance_count = 0
	_mark_next = 0
	_last_mark = [null, null]


func _add_mark(from: Vector3, to: Vector3, tint: Color) -> void:
	var along := to - from
	var length := along.length()
	var x := along / length
	var z := x.cross(Vector3.UP).normalized()
	var basis := Basis(x * (length + 0.06), Vector3.UP, z * 0.24)
	_marks.set_instance_transform(_mark_next, Transform3D(basis, (from + to) * 0.5))
	_marks.set_instance_color(_mark_next, tint)
	_mark_next = (_mark_next + 1) % MARK_COUNT
	_marks.visible_instance_count = maxi(_marks.visible_instance_count, _mark_next if _mark_next > 0 else MARK_COUNT)


func _place(particles: CPUParticles3D, at: Vector3, heading: float, on: bool) -> void:
	particles.global_position = at
	particles.global_rotation = Vector3(0, -heading, 0)
	if particles.emitting != on:
		particles.emitting = on
		particles.set_meta("off_at", Time.get_ticks_msec())
	# Hidden once the last puff has faded, so idle emitters cost no draw call.
	if on:
		particles.visible = true
	elif particles.visible and Time.get_ticks_msec() - int(particles.get_meta("off_at", 0)) > particles.lifetime * 1000.0 + 100.0:
		particles.visible = false


## A soft, round, camera-facing puff that grows and fades. `size` is start and end scale.
func _puffs(color: Color, amount: int, lifetime: float, size: Vector2, rise: float) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.emitting = false
	particles.amount = amount
	particles.lifetime = lifetime
	particles.local_coords = false
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = Vector3(0.15, 0.05, TRACK_HALF)
	particles.direction = Vector3(-1, 0.6, 0)
	particles.spread = 35.0
	particles.initial_velocity_min = 0.6
	particles.initial_velocity_max = 2.0
	particles.gravity = Vector3(0, rise, 0)
	particles.damping_min = 1.5
	particles.damping_max = 3.0
	var curve := Curve.new()
	curve.add_point(Vector2(0, size.x / maxf(size.x, size.y)))
	curve.add_point(Vector2(1, size.y / maxf(size.x, size.y)))
	particles.scale_amount_curve = curve
	particles.scale_amount_min = maxf(size.x, size.y) * 0.8
	particles.scale_amount_max = maxf(size.x, size.y)
	var ramp := Gradient.new()
	ramp.set_color(0, color)
	ramp.set_color(1, Color(color.r, color.g, color.b, 0.0))
	particles.color_ramp = ramp

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 64
	texture.height = 64
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = material
	particles.mesh = quad
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visible = false
	add_child(particles)
	return particles
