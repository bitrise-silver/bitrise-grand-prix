extends Area3D
## A floating icon box on the track. "boost" speeds the car up, "obstacle" slows it down.
## Pickups only exist on each player's own device, so one player hitting a bug does not
## clear it for anyone else.

const Models := preload("res://scripts/models.gd")
const Track := preload("res://scripts/track.gd")
const ICON_DIR := "res://assets/icons/"
const SIZE := 1.7
const HOVER_HEIGHT := 1.45
const OBSTACLE_RESPAWN_SECONDS := 3.0
const BOOST_COLOR := Color("#11bba9")
const BUG_COLOR := Color("#f7596c")

var kind := "boost"

var _cube: Node3D
var _ring: MeshInstance3D
var _ring_material: StandardMaterial3D
var _burst: CPUParticles3D
var _debris: CPUParticles3D
var _active := true
var _time := 0.0


## An icon box with glowing edges. Also used for the ramp marker and the finish gantry.
static func icon_cube(icon: String, edge: Color, size: float) -> Node3D:
	var root := Node3D.new()
	var core := BoxMesh.new()
	core.size = Vector3.ONE * size
	var face := StandardMaterial3D.new()
	face.albedo_texture = load(ICON_DIR + icon + ".svg")
	# BoxMesh lays its faces out on a 3x2 grid; tiling 3x2 puts one full icon on each face.
	face.uv1_scale = Vector3(3, 2, 1)
	face.texture_repeat = true
	face.roughness = 0.35
	face.emission_enabled = true
	face.emission = edge
	face.emission_energy_multiplier = 0.25
	var core_instance := MeshInstance3D.new()
	core_instance.mesh = core
	core_instance.material_override = face
	root.add_child(core_instance)

	# Twelve edge bars that glow, so the box reads as a bright object from far away. One mesh.
	var glow := StandardMaterial3D.new()
	glow.albedo_color = edge.lightened(0.25)
	glow.emission_enabled = true
	glow.emission = edge
	glow.emission_energy_multiplier = 1.6
	var bar := size * 0.09
	var reach := size * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for axis in 3:
		var extent := Vector3.ONE * bar
		extent[axis] = size + bar
		for u in [-1.0, 1.0]:
			for v in [-1.0, 1.0]:
				var at := Vector3.ZERO
				at[(axis + 1) % 3] = u * reach
				at[(axis + 2) % 3] = v * reach
				Track.box_into(st, Transform3D(Basis.IDENTITY, at), extent, Color.WHITE)
	var edges := MeshInstance3D.new()
	edges.mesh = st.commit()
	edges.material_override = glow
	edges.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(edges)
	return root


func _ready() -> void:
	var color := BOOST_COLOR if kind == "boost" else BUG_COLOR
	_cube = icon_cube(kind, color, SIZE)
	_cube.position.y = HOVER_HEIGHT
	add_child(_cube)

	# A ring painted on the road that pulses, so the box is easy to aim for (or avoid).
	var ring := TorusMesh.new()
	ring.inner_radius = 1.25
	ring.outer_radius = 1.5
	ring.rings = 32
	ring.ring_segments = 4
	_ring_material = StandardMaterial3D.new()
	_ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_material.albedo_color = Color(color.r, color.g, color.b, 0.55)
	_ring = MeshInstance3D.new()
	_ring.mesh = ring
	_ring.material_override = _ring_material
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.scale = Vector3(1, 0.05, 1)
	_ring.position.y = 0.1
	add_child(_ring)

	_burst = _sparks(color)
	if kind != "boost":
		_debris = _parts()

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(SIZE + 0.5, 3.0, SIZE + 0.5)
	shape.shape = box
	shape.position.y = 1.5
	add_child(shape)

	_time = randf() * TAU
	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	_time += delta
	if kind == "boost":
		_cube.rotation.y += delta * 1.6
		_cube.position.y = HOVER_HEIGHT + sin(_time * 2.4) * 0.18
	else:
		# Bugs are glitchy: a slow wobble with the odd twitch.
		_cube.rotation.y -= delta * 0.9
		var twitch := 0.12 if fmod(_time, 1.7) < 0.08 else 0.0
		_cube.rotation.z = sin(_time * 5.0) * 0.08 + twitch
		_cube.position.y = HOVER_HEIGHT + sin(_time * 3.1) * 0.12
	var pulse := 0.5 + 0.5 * sin(_time * 3.0)
	var ring_scale := 1.0 + pulse * 0.12
	_ring.scale = Vector3(ring_scale, 0.05, ring_scale)
	_ring_material.albedo_color.a = (0.3 + 0.35 * pulse) if _active else 0.08


func _on_body_entered(body: Node3D) -> void:
	if not _active or not body.has_method("apply_effect"):
		return
	body.call("apply_effect", kind)
	_flash(_burst)

	var tween := create_tween()
	if kind == "boost":
		# Stays in place and just pulses: every lap gets its cache hit.
		tween.tween_property(_cube, "scale", Vector3.ONE * 1.5, 0.08)
		tween.tween_property(_cube, "scale", Vector3.ONE, 0.25)
	else:
		# Squashed bug: bolts fly, then it crawls back.
		_flash(_debris)
		_active = false
		tween.tween_property(_cube, "scale", Vector3(1.6, 0.05, 1.6), 0.12)
		tween.tween_interval(OBSTACLE_RESPAWN_SECONDS)
		tween.tween_property(_cube, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_callback(func() -> void: _active = true)


## Shows a one-shot emitter for as long as its particles live; hidden, it costs no draw call.
func _flash(particles: CPUParticles3D) -> void:
	particles.visible = true
	particles.restart()
	get_tree().create_timer(particles.lifetime + 0.1).timeout.connect(func() -> void: particles.visible = false)


## A one-shot ring of glowing sparks.
func _sparks(color: Color) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.one_shot = true
	particles.emitting = false
	particles.amount = 28
	particles.lifetime = 0.6
	particles.explosiveness = 1.0
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = 0.8
	particles.direction = Vector3.UP
	particles.spread = 180.0
	particles.initial_velocity_min = 6.0
	particles.initial_velocity_max = 11.0
	particles.gravity = Vector3(0, -12, 0)
	particles.damping_min = 4.0
	particles.damping_max = 6.0
	particles.scale_amount_min = 0.18
	particles.scale_amount_max = 0.32
	var ramp := Gradient.new()
	ramp.set_color(0, color.lightened(0.4))
	ramp.set_color(1, Color(color.r, color.g, color.b, 0.0))
	particles.color_ramp = ramp
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = material
	particles.mesh = mesh
	particles.position.y = HOVER_HEIGHT
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visible = false
	add_child(particles)
	return particles


## Nuts and bolts from Kenney's Car Kit, flung out when a car squashes a bug.
func _parts() -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.one_shot = true
	particles.emitting = false
	particles.amount = 10
	particles.lifetime = 1.1
	particles.explosiveness = 1.0
	particles.direction = Vector3.UP
	particles.spread = 70.0
	particles.initial_velocity_min = 5.0
	particles.initial_velocity_max = 9.0
	particles.gravity = Vector3(0, -24, 0)
	particles.angular_velocity_min = -540.0
	particles.angular_velocity_max = 540.0
	particles.scale_amount_min = 1.6
	particles.scale_amount_max = 2.4
	particles.mesh = Models.kit_mesh("debris-bolt")
	particles.position.y = HOVER_HEIGHT
	particles.visible = false
	add_child(particles)
	return particles
