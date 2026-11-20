extends RefCounted
## Loads the CC0 models from Kenney's Car Kit and Nature Kit (see game/assets/models) and
## recolours them in a Bitrise-flavoured palette. Meshes are cached, so asking twice is cheap.

const CAR_SCENE := "res://assets/models/car/hatchback-sports.glb"
const CAR_KIT := "res://assets/models/car/%s.glb"
const NATURE_KIT := "res://assets/models/nature/%s.glb"
const PAINT := preload("res://shaders/car_paint.gdshader")
const GHOST := preload("res://shaders/car_ghost.gdshader")

## Nature Kit material names and the colours they get here.
const NATURE_COLORS := {
	"leafsDark": Color("#2f6e48"),
	"leafsGreen": Color("#4c9a4f"),
	"woodBark": Color("#8a5a3c"),
	"woodBarkDark": Color("#5e3d2c"),
	"grass": Color("#5a9c4b"),
	"dirt": Color("#8d8496"),
	"stone": Color("#b3abbd"),
	"_defaultMat": Color("#a69eb0"),
}

static var _meshes := {}
static var _paints := {}
static var _colormap: Texture2D


## A Nature Kit model as one mesh. `overrides` maps material names to colours, for variants
## such as purple-leaved trees.
static func nature_mesh(model: String, overrides := {}) -> Mesh:
	var key := model + str(overrides)
	if _meshes.has(key):
		return _meshes[key]
	var source := _first_mesh(load(NATURE_KIT % model))
	var mesh: ArrayMesh = source.duplicate()
	for i in mesh.get_surface_count():
		var original := mesh.surface_get_material(i)
		var material_name := original.resource_name if original else ""
		var flat := StandardMaterial3D.new()
		flat.albedo_color = overrides.get(material_name, NATURE_COLORS.get(material_name, Color.WHITE))
		flat.roughness = 0.9
		mesh.surface_set_material(i, flat)
	_meshes[key] = mesh
	return mesh


## A Nature Kit model as a single surface with its colours baked into vertex colours, so many
## different models can be merged into one mesh and drawn in one go (see scenery.gd).
static func baked_mesh(model: String, overrides := {}) -> ArrayMesh:
	var key := "baked:" + model + str(overrides)
	if _meshes.has(key):
		return _meshes[key]
	var coloured := nature_mesh(model, overrides)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in coloured.get_surface_count():
		var material := coloured.surface_get_material(i) as StandardMaterial3D
		var color := material.albedo_color if material else Color.WHITE
		var arrays := coloured.surface_get_arrays(i)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			indices = PackedInt32Array(range(vertices.size()))
		for index in indices:
			st.set_color(color)
			st.set_normal(normals[index])
			st.add_vertex(vertices[index])
	st.index()
	var mesh := st.commit()
	_meshes[key] = mesh
	return mesh


## A Car Kit prop (cone, debris) with its own palette material.
static func kit_mesh(model: String) -> Mesh:
	var key := "kit:" + model
	if not _meshes.has(key):
		_meshes[key] = _first_mesh(load(CAR_KIT % model))
	return _meshes[key]


## The sporty hatchback, painted. `opacity` below 1 makes a see-through ghost that casts no shadow.
static func car(paint: Color, opacity := 1.0) -> Node3D:
	var scene: PackedScene = load(CAR_SCENE)
	var root: Node3D = scene.instantiate()
	var material := _paint(paint, opacity)
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node
		instance.material_override = material
		if opacity < 1.0:
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root


## The hatchback merged into a single mesh (body and wheels together): one draw call, but
## the wheels cannot turn. Used for see-through ghosts on phones.
static func car_merged(paint: Color, opacity := 1.0) -> MeshInstance3D:
	if not _meshes.has("car:merged"):
		var scene: PackedScene = load(CAR_SCENE)
		var root: Node3D = scene.instantiate()
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for node in root.find_children("*", "MeshInstance3D", true, false):
			var part: MeshInstance3D = node
			var placement := Transform3D.IDENTITY
			var walker: Node = part
			while walker != root and walker is Node3D:
				placement = (walker as Node3D).transform * placement
				walker = walker.get_parent()
			for surface in part.mesh.get_surface_count():
				st.append_from(part.mesh, surface, placement)
		root.free()
		_meshes["car:merged"] = st.commit()
	var instance := MeshInstance3D.new()
	instance.mesh = _meshes["car:merged"]
	instance.material_override = _paint(paint, opacity)
	if opacity < 1.0:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


static func _paint(paint: Color, opacity: float) -> ShaderMaterial:
	var key := "%s/%.2f" % [paint.to_html(false), opacity]
	if _paints.has(key):
		return _paints[key]
	if not _colormap:
		var probe := _first_mesh(load(CAR_SCENE))
		var original := probe.surface_get_material(0) as BaseMaterial3D
		_colormap = original.albedo_texture if original else null
	var material := ShaderMaterial.new()
	material.shader = GHOST if opacity < 1.0 else PAINT
	material.set_shader_parameter("colormap", _colormap)
	material.set_shader_parameter("paint", paint)
	if opacity < 1.0:
		material.set_shader_parameter("opacity", opacity)
	_paints[key] = material
	return material


static func _first_mesh(scene: PackedScene) -> Mesh:
	var root := scene.instantiate()
	var found: Mesh = null
	for node in root.find_children("*", "MeshInstance3D", true, false):
		found = (node as MeshInstance3D).mesh
		break
	if not found and root is MeshInstance3D:
		found = (root as MeshInstance3D).mesh
	root.free()
	return found
