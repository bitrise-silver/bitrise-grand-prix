extends Node3D
## The look of an RC car: Kenney's sporty hatchback (CC0) in the driver's colour, with
## steering, spinning wheels and a wobbly RC antenna. Used for the player's own car and,
## see-through, for other players' ghosts.
## Local +X is forward; the origin sits on the ground under the middle of the car.

const Models := preload("res://scripts/models.gd")
const Track := preload("res://scripts/track.gd")

## The model is 2.9 units long; this makes it the length the car's physics expect.
const MODEL_SCALE := 0.8
const WHEEL_RADIUS := 0.3 * MODEL_SCALE
## How far the front wheels turn at full lock, in radians. More than a real car, so it reads
## from the high camera.
const STEER_ANGLE := 0.62
## How far the body leans out of a hard corner, in radians.
const LEAN_ANGLE := 0.09
## Bitrise livery, over the driver's own colour.
const ROOF_DECAL := "res://assets/icons/car-roof.svg"
const COL_STRIPE := Color("#f6f4f6")
const COL_WING := Color("#2b0e3f")
const COL_WING_TIP := Color("#f9cc15")
## Every car's livery is the same, so it is built once and shared.
static var _livery_mesh: Mesh
static var _livery_material: StandardMaterial3D
static var _roof_mesh: Mesh
static var _roof_material: StandardMaterial3D

var color := Color("#9247c2")
var ghost := false
var display_name := ""

var _front_wheels: Array[Node3D] = []
var _wheels: Array[Node3D] = []
var _body: Node3D
var _antenna: Node3D
var _label: Label3D
var _glow: MeshInstance3D
var _time := 0.0
var _spin := 0.0
var _steer := 0.0
var _steer_shown := 0.0
var _lean := 0.0
var _lean_shown := 0.0
var _wheel_speed := 0.0


func _ready() -> void:
	# Ghosts on a phone are one merged mesh: cheaper, and nobody sees their wheels turn.
	var model: Node3D = Models.car_merged(color, 0.5) if ghost else Models.car(color)
	model.scale = Vector3.ONE * MODEL_SCALE
	# The model faces +Z; this node faces +X.
	model.rotation.y = PI * 0.5
	add_child(model)
	for wheel_name in ["wheel-front-left", "wheel-front-right", "wheel-back-left", "wheel-back-right"]:
		var wheel := model.find_child(wheel_name, true, false) as Node3D
		if wheel:
			_wheels.append(wheel)
			if wheel_name.begins_with("wheel-front"):
				_front_wheels.append(wheel)
	_body = model.find_child("body", true, false) as Node3D
	if _body and not ghost:
		_add_livery()

	# Every RC car needs a wobbly antenna.
	_antenna = Node3D.new()
	_antenna.position = Vector3(-0.85, 0.62, 0.32)
	add_child(_antenna)
	# Rod and tip in one mesh, one draw call.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	Track.box_into(st, Transform3D(Basis.IDENTITY, Vector3(0, 0.55, 0)), Vector3(0.045, 1.1, 0.045), Color(0.13, 0.1, 0.15))
	Track.box_into(st, Transform3D(Basis.IDENTITY, Vector3(0, 1.1, 0)), Vector3.ONE * 0.17, Color("#f9cc15"))
	var antenna_material := StandardMaterial3D.new()
	antenna_material.vertex_color_use_as_albedo = true
	if ghost:
		antenna_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		antenna_material.albedo_color.a = 0.5
	var rod_instance := MeshInstance3D.new()
	rod_instance.mesh = st.commit()
	rod_instance.material_override = antenna_material
	if ghost:
		rod_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_antenna.add_child(rod_instance)

	# Underglow that lights up while a boost or a slow-down is active.
	var glow := QuadMesh.new()
	glow.size = Vector2(3.4, 2.2)
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	var glow_material := StandardMaterial3D.new()
	glow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	glow_material.albedo_texture = texture
	glow_material.albedo_color = Color(1, 1, 1, 0)
	_glow = MeshInstance3D.new()
	_glow.mesh = glow
	_glow.material_override = glow_material
	_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glow.rotation.x = -PI * 0.5
	_glow.position.y = 0.12
	_glow.visible = false
	add_child(_glow)

	if not display_name.is_empty():
		_label = Label3D.new()
		_label.text = display_name
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.fixed_size = false
		_label.font_size = 64
		_label.pixel_size = 0.018
		_label.outline_size = 16
		_label.modulate = color.lightened(0.55)
		_label.position = Vector3(0, 2.4, 0)
		add_child(_label)


## The Bitrise badge on the roof, twin stripes on the bonnet and a wing with yellow end plates.
## The paint stays the driver's colour, so cars still tell apart. Solid cars only: see-through
## ghosts stay plain, which keeps them cheap on phones. Built on the body, in the model's own
## space (facing +Z, 1.3 wide, the roof about 1.0 up), so it leans with the body.
func _add_livery() -> void:
	if not _livery_mesh:
		var parts := SurfaceTool.new()
		parts.begin(Mesh.PRIMITIVE_TRIANGLES)
		for side in [-0.13, 0.13]:
			Track.box_into(parts, Transform3D(Basis.IDENTITY, Vector3(side, 0.695, 0.82)), Vector3(0.1, 0.012, 0.42), COL_STRIPE)
		for side in [-0.32, 0.32]:
			Track.box_into(parts, Transform3D(Basis.IDENTITY, Vector3(side, 0.92, -1.26)), Vector3(0.05, 0.2, 0.08), COL_WING)
		Track.box_into(parts, Transform3D(Basis.IDENTITY, Vector3(0, 1.03, -1.28)), Vector3(1.12, 0.05, 0.3), COL_WING)
		for side in [-0.58, 0.58]:
			Track.box_into(parts, Transform3D(Basis.IDENTITY, Vector3(side, 1.0, -1.28)), Vector3(0.04, 0.18, 0.34), COL_WING_TIP)
		_livery_mesh = parts.commit()
		_livery_material = StandardMaterial3D.new()
		_livery_material.vertex_color_use_as_albedo = true
		_livery_material.roughness = 0.5
		_roof_mesh = QuadMesh.new()
		(_roof_mesh as QuadMesh).size = Vector2(0.62, 0.62)
		_roof_material = StandardMaterial3D.new()
		_roof_material.albedo_texture = load(ROOF_DECAL)
		_roof_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		_roof_material.alpha_scissor_threshold = 0.5
		_roof_material.roughness = 0.45

	var livery := MeshInstance3D.new()
	livery.mesh = _livery_mesh
	livery.material_override = _livery_material
	_body.add_child(livery)
	var roof := MeshInstance3D.new()
	roof.mesh = _roof_mesh
	roof.material_override = _roof_material
	roof.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Flat on the roof, with the top of the badge towards the front of the car.
	roof.transform = Transform3D(Basis(Vector3.UP, PI) * Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, 1.012, -0.22))
	_body.add_child(roof)


func _process(delta: float) -> void:
	_time += delta
	_antenna.rotation.z = sin(_time * 9.0) * 0.07 + clampf(_wheel_speed * 0.012, -0.25, 0.25)
	_spin = wrapf(_spin + _wheel_speed / WHEEL_RADIUS * delta, -PI, PI)
	# Eased, so the wheels swing over rather than snap, like a steering servo.
	_steer_shown = lerpf(_steer_shown, _steer, 1.0 - exp(-14.0 * delta))
	for wheel in _wheels:
		var steer := -_steer_shown * STEER_ANGLE if _front_wheels.has(wheel) else 0.0
		wheel.rotation = Vector3(_spin, steer, 0.0)
	# The body rolls towards the outside of the corner; the wheels stay on the ground.
	_lean_shown = lerpf(_lean_shown, _lean, 1.0 - exp(-7.0 * delta))
	if _body:
		_body.rotation.z = -_lean_shown * LEAN_ANGLE


## steer: -1 (left) to 1 (right).
func set_steer(steer: float) -> void:
	_steer = steer


## How hard the car is cornering: -1 (hard left) to 1 (hard right). Leans the body.
func set_lean(lean: float) -> void:
	_lean = clampf(lean, -1.0, 1.0)


## Forward speed in units per second; spins the wheels.
func set_wheel_speed(speed: float) -> void:
	_wheel_speed = speed


## effect: 0 none, 1 boosted, 2 slowed.
func set_effect(effect: int) -> void:
	if not _glow:
		return
	var material: StandardMaterial3D = _glow.material_override
	_glow.visible = effect != 0
	match effect:
		1:
			material.albedo_color = Color(0.07, 0.95, 0.85, 0.85)
		2:
			material.albedo_color = Color(0.97, 0.2, 0.28, 0.85)
		_:
			material.albedo_color = Color(1, 1, 1, 0)


func set_label_scale(value: float) -> void:
	if _label:
		_label.pixel_size = 0.018 * value
