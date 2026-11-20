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

var color := Color("#9247c2")
var ghost := false
var display_name := ""

var _front_wheels: Array[Node3D] = []
var _wheels: Array[Node3D] = []
var _antenna: Node3D
var _label: Label3D
var _glow: MeshInstance3D
var _time := 0.0
var _spin := 0.0
var _steer := 0.0
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


func _process(delta: float) -> void:
	_time += delta
	_antenna.rotation.z = sin(_time * 9.0) * 0.07 + clampf(_wheel_speed * 0.012, -0.25, 0.25)
	_spin = wrapf(_spin + _wheel_speed / WHEEL_RADIUS * delta, -PI, PI)
	for wheel in _wheels:
		var steer := -_steer * 0.45 if _front_wheels.has(wheel) else 0.0
		wheel.rotation = Vector3(_spin, steer, 0.0)


## steer: -1 (left) to 1 (right).
func set_steer(steer: float) -> void:
	_steer = steer


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
