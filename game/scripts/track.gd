extends Node3D
## Builds the drivable part of a track from a JSON file in res://tracks: road, kerbs, sand
## traps, Armco barriers, the start/finish line, ramps, walls and pickups, and the lights on
## them (start lights, chase lights, bend markers, road studs). Scenery (grass, trees, crowds,
## flags) is scenery.gd's job. Also answers "is this point on the road?" and holds the gates
## used for lap counting.

const Pickup := preload("res://scripts/pickup.gd")
const ROAD_SHADER := preload("res://shaders/road.gdshader")
const LIGHTS_SHADER := preload("res://shaders/lights.gdshader")

const SAMPLES_PER_SEGMENT := 12
const ICON_DIR := "res://assets/icons/"

## Curvature (1/radius) above which a bend gets kerbs, and above which its outside gets sand.
const KERB_CURVATURE := 0.022
const SAND_CURVATURE := 0.03
const KERB_WIDTH := 1.1
## Barriers sit this far outside the road's edge.
const BARRIER_GAP := 8.5

const COL_KERB_A := Color("#9247c2")
const COL_KERB_B := Color("#f6f4f6")
const COL_LINE := Color("#ece8f0")
const COL_SAND := Color("#c9ad78")
const COL_SAND_EDGE := Color("#b39360")
const COL_RAIL := Color("#dcd7e3")
const COL_RAIL_SHADE := Color("#a59cb2")
const COL_POST := Color("#5b2a86")
const COL_PILLAR := Color("#6c2fa0")
const COL_BEAM := Color("#2b0e3f")
const COL_CONCRETE := Color("#cfc9d6")
const COL_HAZARD := Color("#f9cc15")
const COL_DARK := Color("#201b22")
const COL_LAMP_OFF := Color(0.16, 0.13, 0.19)
const COL_LAMP_RED := Color(1.0, 0.12, 0.14)
const COL_LAMP_GREEN := Color(0.1, 1.0, 0.5)
const COL_LAMP_AMBER := Color(1.0, 0.62, 0.08)
const START_LAMPS := 5
## Road studs: one every this many centreline samples, and how far a pulse travels per cycle.
const STUD_EVERY := 3
const STUD_WAVE := 26.0

var data: Dictionary = {}
var track_id := ""
var road_width := 10.0
var arena_half := Vector2(84, 64)

## Sampled centreline in the XZ plane, closed (the last point connects back to the first).
var path := PackedVector2Array()
var path_length := 0.0
## Unit driving direction and signed curvature (positive bends right) at every sample.
var tangents := PackedVector2Array()
var curvature := PackedFloat32Array()
## Lap gates in driving order; the last one is the finish line.
## Each is { pos: Vector2, dir: Vector2, half: float }.
var gates: Array[Dictionary] = []
var spawn_position := Vector3.ZERO
var spawn_heading := 0.0
## Ground already taken by the track's own structures, so scenery stays clear of it.
var occupied: Array[Rect2] = []
## Barrier runs, each a list of points; scenery puts crowds and boards behind them.
## Each is { points: PackedVector2Array, side: float, indices: PackedInt32Array }.
var barriers: Array[Dictionary] = []

var _control: Array[Vector2] = []
var _shortcuts: Array[Dictionary] = []
var _spinners: Array[Node3D] = []
var _start_lamps: MultiMesh
var _start_material: ShaderMaterial
## Small solid parts (gantry, wall blocks, rails) merged into one mesh: one draw call, not dozens.
var _static: SurfaceTool


static func read_track_file(id: String) -> Dictionary:
	var file_path := "res://tracks/%s.json" % id
	if not FileAccess.file_exists(file_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file_path))
	return parsed if parsed is Dictionary else {}


func build(id: String) -> bool:
	data = read_track_file(id)
	if data.is_empty():
		push_error("Track '%s' could not be loaded." % id)
		return false
	track_id = id
	road_width = float(data.get("roadWidth", 10.0))
	var arena: Dictionary = data.get("arena", {})
	arena_half = Vector2(float(arena.get("halfWidth", 84)), float(arena.get("halfDepth", 64)))

	_control.clear()
	for point: Array in data.get("centerline", []):
		_control.append(Vector2(float(point[0]), float(point[1])))
	_sample_path()
	_read_shortcuts()
	_static = SurfaceTool.new()
	_static.begin(Mesh.PRIMITIVE_TRIANGLES)

	_build_bounds()
	_build_road()
	_build_shortcuts()
	_build_sand()
	_build_gates()
	_build_finish()
	for ramp: Dictionary in data.get("ramps", []):
		_build_ramp(ramp)
	for wall: Dictionary in data.get("walls", []):
		_build_wall(wall)
	_build_barriers()
	_build_road_studs()
	var solid := _flat_material()
	solid.cull_mode = BaseMaterial3D.CULL_BACK
	solid.roughness = 0.75
	_add_mesh(_static.commit(), solid)
	for item: Dictionary in data.get("boosts", []):
		_add_pickup("boost", item)
	for item: Dictionary in data.get("obstacles", []):
		_add_pickup("obstacle", item)

	# Start a few metres before the line, like a real grid.
	var start_at := float(_control.size()) - 0.22
	var start := point_at(start_at)
	var tangent := tangent_at(start_at)
	spawn_position = Vector3(start.x, 0.0, start.y)
	spawn_heading = atan2(tangent.y, tangent.x)
	return true


func _process(delta: float) -> void:
	for spinner in _spinners:
		spinner.rotate_y(delta * 0.9)


# --- geometry queries -------------------------------------------------------------------------

## Position on the centreline. `at` is in control-point units: 2.5 is halfway between
## control points 2 and 3.
func point_at(at: float) -> Vector2:
	var n := _control.size()
	var i := int(floor(at))
	var t := at - float(i)
	var p0 := _control[posmod(i - 1, n)]
	var p1 := _control[posmod(i, n)]
	var p2 := _control[posmod(i + 1, n)]
	var p3 := _control[posmod(i + 2, n)]
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


## Unit driving direction on the centreline.
func tangent_at(at: float) -> Vector2:
	var n := _control.size()
	var i := int(floor(at))
	var t := at - float(i)
	var p0 := _control[posmod(i - 1, n)]
	var p1 := _control[posmod(i, n)]
	var p2 := _control[posmod(i + 1, n)]
	var p3 := _control[posmod(i + 2, n)]
	var d := 0.5 * ((-p0 + p2) + 2.0 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t + 3.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t)
	return d.normalized()


## The right-hand side of the driving direction. Positive offsets in track files go this way,
## which is the outside of an anticlockwise loop.
static func right_of(tangent: Vector2) -> Vector2:
	return Vector2(-tangent.y, tangent.x)


func is_on_road(pos: Vector3) -> bool:
	var p := Vector2(pos.x, pos.z)
	var limit := road_width * 0.5 + 0.6
	var limit_sq := limit * limit
	var count := path.size()
	for i in count:
		if _segment_distance_sq(p, path[i], path[(i + 1) % count]) <= limit_sq:
			return true
	for shortcut in _shortcuts:
		var points: PackedVector2Array = shortcut.points
		var half: float = shortcut.half
		for i in points.size() - 1:
			if _segment_distance_sq(p, points[i], points[i + 1]) <= half * half:
				return true
	return false


## Distance from `p` to the nearest drivable surface (road centreline minus half its width, or
## a shortcut strip). Negative on the road.
func distance_to_road(p: Vector2) -> float:
	var best := INF
	var count := path.size()
	for i in count:
		best = minf(best, _segment_distance_sq(p, path[i], path[(i + 1) % count]))
	var result := sqrt(best) - road_width * 0.5
	for shortcut in _shortcuts:
		var points: PackedVector2Array = shortcut.points
		for i in points.size() - 1:
			result = minf(result, sqrt(_segment_distance_sq(p, points[i], points[i + 1])) - float(shortcut.half))
	return result


## True when `rect` overlaps something the track already built (stands, ramps, signs).
func is_occupied(rect: Rect2) -> bool:
	for taken in occupied:
		if taken.intersects(rect):
			return true
	return false


## Index of the centreline sample closest to `pos`. Pass the previous answer as `hint` to
## search only nearby samples.
func nearest_path_index(pos: Vector3, hint := -1) -> int:
	var p := Vector2(pos.x, pos.z)
	var count := path.size()
	var best := 0
	var best_sq := INF
	var from := 0
	var span := count
	if hint >= 0:
		from = hint - 6
		span = 30
	for k in span:
		var i := posmod(from + k, count)
		var d := p.distance_squared_to(path[i])
		if d < best_sq:
			best_sq = d
			best = i
	return best


static func _segment_distance_sq(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq < 0.0001:
		return p.distance_squared_to(a)
	var t := clampf((p - a).dot(ab) / length_sq, 0.0, 1.0)
	return p.distance_squared_to(a + ab * t)


func _sample_path() -> void:
	path = PackedVector2Array()
	path_length = 0.0
	for i in _control.size():
		for s in SAMPLES_PER_SEGMENT:
			path.append(point_at(float(i) + float(s) / SAMPLES_PER_SEGMENT))
	var count := path.size()
	for i in count:
		path_length += path[i].distance_to(path[(i + 1) % count])

	tangents = PackedVector2Array()
	for i in count:
		tangents.append((path[(i + 1) % count] - path[posmod(i - 1, count)]).normalized())
	# Curvature from the turn between neighbouring tangents, smoothed so kerbs and sand traps
	# cover the whole bend instead of flickering on and off.
	var raw := PackedFloat32Array()
	for i in count:
		var a := tangents[posmod(i - 2, count)]
		var b := tangents[(i + 2) % count]
		var span := path[posmod(i - 2, count)].distance_to(path[(i + 2) % count])
		raw.append(a.angle_to(b) / maxf(span, 0.01))
	curvature = PackedFloat32Array()
	for i in count:
		var total := 0.0
		for k in range(-3, 4):
			total += raw[posmod(i + k, count)]
		curvature.append(total / 7.0)


func _read_shortcuts() -> void:
	_shortcuts.clear()
	for shortcut: Dictionary in data.get("shortcuts", []):
		var points := PackedVector2Array()
		for point: Array in shortcut.get("points", []):
			points.append(Vector2(float(point[0]), float(point[1])))
		var half := float(shortcut.get("width", 6.0)) * 0.5
		_shortcuts.append({"points": points, "half": half + 0.4, "draw_half": half})


# --- construction -----------------------------------------------------------------------------

static func _flat_material(vertex_colors := true) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = vertex_colors
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 0.95
	return material


static func _solid(color: Color, roughness := 0.8) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material


func _road_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = ROAD_SHADER
	return material


func _add_mesh(mesh: Mesh, material: Material, at := Vector3.ZERO, parent: Node3D = self) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	return instance


func _add_box_body(size: Vector3, at: Vector3, yaw := 0.0, parent: Node3D = self) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	body.rotation.y = yaw
	parent.add_child(body)
	return body


## Godot treats clockwise triangles as front faces; the quad is wound to face `normal`.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color, normal := Vector3.UP) -> void:
	var order := [a, c, b, a, d, c] if (b - a).cross(c - a).dot(normal) > 0.0 else [a, b, c, a, c, d]
	for v: Vector3 in order:
		st.set_normal(normal)
		st.set_color(color)
		st.add_vertex(v)


## A quad with UVs: u across (a->b), v along (a->d).
static func _quad_uv(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color, u: Vector2, v: Vector2) -> void:
	var points := [a, b, c, a, c, d]
	var uvs := [Vector2(u.x, v.x), Vector2(u.y, v.x), Vector2(u.y, v.y), Vector2(u.x, v.x), Vector2(u.y, v.y), Vector2(u.x, v.y)]
	if (b - a).cross(c - a).dot(Vector3.UP) > 0.0:
		points = [a, c, b, a, d, c]
		uvs = [uvs[0], uvs[2], uvs[1], uvs[0], uvs[5], uvs[2]]
	for k in 6:
		st.set_normal(Vector3.UP)
		st.set_color(color)
		st.set_uv(uvs[k])
		st.add_vertex(points[k])


## Appends a box of `size`, centred and turned by `xf`, to a vertex-coloured SurfaceTool.
static func box_into(st: SurfaceTool, xf: Transform3D, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	for axis in 3:
		for direction in [-1.0, 1.0]:
			var normal := Vector3.ZERO
			normal[axis] = direction
			var u := Vector3.ZERO
			u[(axis + 1) % 3] = h[(axis + 1) % 3]
			var v := Vector3.ZERO
			v[(axis + 2) % 3] = h[(axis + 2) % 3]
			var center := normal * h
			_quad(st, xf * (center - u - v), xf * (center + u - v), xf * (center + u + v), xf * (center - u + v),
				color, (xf.basis * normal).normalized())


## A box between two ground points, `height` tall starting at `base`, `thickness` wide.
static func _beam(st: SurfaceTool, a: Vector2, b: Vector2, base: float, height: float, thickness: float, color: Color, shade: Color) -> void:
	var along := (b - a).normalized()
	var side := Vector2(-along.y, along.x) * thickness * 0.5
	var top := base + height
	var corners := [a - side, a + side, b + side, b - side]
	# Top.
	_quad(st, _v(corners[0], top), _v(corners[1], top), _v(corners[2], top), _v(corners[3], top), color)
	# Both long faces.
	for k: int in [0, 1]:
		var p: Vector2 = corners[0] if k == 0 else corners[1]
		var q: Vector2 = corners[3] if k == 0 else corners[2]
		var normal := Vector3(-side.x, 0, -side.y).normalized() if k == 0 else Vector3(side.x, 0, side.y).normalized()
		_quad(st, _v(p, base), _v(q, base), _v(q, top), _v(p, top), shade if k == 0 else color, normal)


func _build_bounds() -> void:
	var size := Vector3(arena_half.x * 2.0, 2.0, arena_half.y * 2.0)
	_add_box_body(size + Vector3(40, 0, 40), Vector3(0, -1, 0))
	# Tall invisible walls round the arena, so a jumping car cannot leave it.
	for side in [-1.0, 1.0]:
		_add_box_body(Vector3(arena_half.x * 2.0 + 2.0, 12, 1.0), Vector3(0, 6, side * (arena_half.y + 0.5)))
		_add_box_body(Vector3(1.0, 12, arena_half.y * 2.0 + 2.0), Vector3(side * (arena_half.x + 0.5), 6, 0))


func _build_road() -> void:
	var half := road_width * 0.5
	var count := path.size()
	var road := SurfaceTool.new()
	road.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trim := SurfaceTool.new()
	trim.begin(Mesh.PRIMITIVE_TRIANGLES)

	var lefts: Array[Vector2] = []
	var rights: Array[Vector2] = []
	for i in count:
		var right := right_of(tangents[i])
		lefts.append(path[i] - right * half)
		rights.append(path[i] + right * half)

	var distance := 0.0
	for i in count:
		var j := (i + 1) % count
		var step := path[i].distance_to(path[j])
		_quad_uv(road, _v(lefts[i], 0.04), _v(rights[i], 0.04), _v(rights[j], 0.04), _v(lefts[j], 0.04), Color.WHITE,
			Vector2(0, 1), Vector2(distance, distance + step) / road_width)
		distance += step

		var out_i := (rights[i] - lefts[i]).normalized()
		var out_j := (rights[j] - lefts[j]).normalized()
		# Painted edge lines just inside the asphalt.
		for edge in [-1.0, 1.0]:
			var base_i: Vector2 = path[i] + out_i * edge * (half - 0.35)
			var base_j: Vector2 = path[j] + out_j * edge * (half - 0.35)
			_quad(trim, _v(base_i - out_i * 0.11, 0.055), _v(base_i + out_i * 0.11, 0.055),
				_v(base_j + out_j * 0.11, 0.055), _v(base_j - out_j * 0.11, 0.055), COL_LINE)

		# Kerbs only where the road bends, like a real circuit.
		if absf(curvature[i]) < KERB_CURVATURE:
			continue
		var kerb := COL_KERB_A if (i / 2) % 2 == 0 else COL_KERB_B
		var w_i := out_i * KERB_WIDTH
		var w_j := out_j * KERB_WIDTH
		_quad(trim, _v(rights[i], 0.07), _v(rights[i] + w_i, 0.06), _v(rights[j] + w_j, 0.06), _v(rights[j], 0.07), kerb)
		_quad(trim, _v(lefts[i] - w_i, 0.06), _v(lefts[i], 0.07), _v(lefts[j], 0.07), _v(lefts[j] - w_j, 0.06), kerb)

	var road_instance := _add_mesh(road.commit(), _road_material())
	road_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var trim_instance := _add_mesh(trim.commit(), _flat_material())
	trim_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_shortcuts() -> void:
	for shortcut in _shortcuts:
		var points: PackedVector2Array = shortcut.points
		var half: float = shortcut.draw_half
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var distance := 0.0
		for i in points.size() - 1:
			var side := right_of((points[i + 1] - points[i]).normalized()) * half
			var step := points[i].distance_to(points[i + 1])
			_quad_uv(st, _v(points[i] - side, 0.045), _v(points[i] + side, 0.045), _v(points[i + 1] + side, 0.045), _v(points[i + 1] - side, 0.045),
				Color(0.92, 0.95, 1.0), Vector2(0, 1), Vector2(distance, distance + step) / (half * 2.0))
			distance += step
		var instance := _add_mesh(st.commit(), _road_material())
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Sand on the outside of the tighter bends, where a car that runs wide ends up.
func _build_sand() -> void:
	var half := road_width * 0.5
	var count := path.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var depth := PackedFloat32Array()
	depth.resize(count)
	for i in count:
		depth[i] = clampf((absf(curvature[i]) - SAND_CURVATURE) / 0.02, 0.0, 1.0) * 6.0
	var any := false
	for i in count:
		var j := (i + 1) % count
		if depth[i] <= 0.01 and depth[j] <= 0.01:
			continue
		# The outside of a right-hand bend is on the left.
		var outside := -signf(curvature[i] if absf(curvature[i]) > 0.0 else curvature[j])
		var n_i := right_of(tangents[i]) * outside
		var n_j := right_of(tangents[j]) * outside
		var start := half + KERB_WIDTH
		var a := path[i] + n_i * start
		var b := path[j] + n_j * start
		var c := path[j] + n_j * (start + depth[j])
		var d := path[i] + n_i * (start + depth[i])
		_quad(st, _v(a, 0.035), _v(b, 0.035), _v(c, 0.035), _v(d, 0.035), COL_SAND)
		# A darker lip on the far edge.
		var c2 := path[j] + n_j * (start + depth[j] + 0.35 * depth[j] / 6.0)
		var d2 := path[i] + n_i * (start + depth[i] + 0.35 * depth[i] / 6.0)
		_quad(st, _v(d, 0.035), _v(c, 0.035), _v(c2, 0.035), _v(d2, 0.035), COL_SAND_EDGE)
		any = true
	if any:
		var instance := _add_mesh(st.commit(), _flat_material())
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_gates() -> void:
	gates.clear()
	var half := road_width * 0.5 + 4.0
	var indices: Array = data.get("checkpoints", [])
	for index: Variant in indices:
		var at := float(index)
		gates.append({"pos": point_at(at), "dir": tangent_at(at), "half": half})
	gates.append({"pos": point_at(0.0), "dir": tangent_at(0.0), "half": half})


func _build_finish() -> void:
	var center := point_at(0.0)
	var tangent := tangent_at(0.0)
	var right := right_of(tangent)
	var half := road_width * 0.5

	# Chequered strip across the road, and grid boxes behind it.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var columns := 10
	var cell := road_width / columns
	for row in 2:
		for column in columns:
			var color := Color.WHITE if (row + column) % 2 == 0 else COL_DARK
			var a := center + right * (-half + column * cell) + tangent * (row * cell - cell)
			var b := a + right * cell
			_quad(st, _v(a, 0.08), _v(b, 0.08), _v(b + tangent * cell, 0.08), _v(a + tangent * cell, 0.08), color)
	for slot in 4:
		var back := 4.5 + slot * 4.0
		var lateral := (half * 0.45) * (1.0 if slot % 2 == 0 else -1.0)
		var corner := center - tangent * back + right * lateral
		var width := 2.2
		# A white bracket: the front bar and two short side bars.
		var front_a := corner - right * width * 0.5
		var front_b := corner + right * width * 0.5
		_quad(st, _v(front_a, 0.075), _v(front_b, 0.075), _v(front_b - tangent * 0.18, 0.075), _v(front_a - tangent * 0.18, 0.075), COL_LINE)
		for end in [front_a, front_b - right * 0.18]:
			var e: Vector2 = end
			_quad(st, _v(e, 0.075), _v(e + right * 0.18, 0.075), _v(e + right * 0.18 - tangent * 1.0, 0.075), _v(e - tangent * 1.0, 0.075), COL_LINE)
	var lines := _add_mesh(st.commit(), _flat_material())
	lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Gantry over the line, decorated with the finish icon.
	var yaw := -atan2(tangent.y, tangent.x)
	var gantry := Node3D.new()
	gantry.position = Vector3(center.x, 0, center.y)
	gantry.rotation.y = yaw
	add_child(gantry)

	var post_offset := half + 1.6
	var frame := gantry.transform
	for side in [-1.0, 1.0]:
		var z: float = side * post_offset
		box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(0, 3.1, z)), Vector3(0.9, 6.2, 0.9), COL_PILLAR)
		box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(0, 4.9, z)), Vector3(0.94, 0.35, 0.94), Color.WHITE)
		box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(0, 0.2, z)), Vector3(1.5, 0.4, 1.5), COL_BEAM)
		var world: Vector3 = gantry.position + Vector3(right.x, 0, right.y) * z
		_add_box_body(Vector3(1.0, 6.0, 1.0), world + Vector3(0, 3.0, 0))
		occupied.append(Rect2(Vector2(world.x, world.z) - Vector2(1.5, 1.5), Vector2(3, 3)))
	box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(0, 6.6, 0)), Vector3(1.0, 1.1, post_offset * 2.0 + 0.9), COL_BEAM)
	box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(0, 6.1, 0)), Vector3(1.04, 0.16, post_offset * 2.0 + 0.94), COL_PILLAR)

	for offset in [-half * 0.55, half * 0.55]:
		var cube := Pickup.icon_cube("finish", Color("#ae63de"), 1.25)
		cube.position = Vector3(0, 7.85, offset)
		gantry.add_child(cube)
		_spinners.append(cube)

	# Five start lights in a housing on top of the beam, between the spinning finish boxes:
	# red one by one, then green.
	var spacing := clampf((half * 0.55 - 1.2) * 0.5, 0.45, 0.7)
	box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(0, 7.26, 0)), Vector3(0.9, 0.22, spacing * 4.0 + 0.8), COL_DARK)
	var lamp_spots: Array[Transform3D] = []
	var lamp_colors: Array[Color] = []
	for k in START_LAMPS:
		lamp_spots.append(Transform3D(Basis.IDENTITY, Vector3(0, 7.55, (k - (START_LAMPS - 1) * 0.5) * spacing)))
		lamp_colors.append(COL_LAMP_OFF)
	var lamp := SphereMesh.new()
	lamp.radius = 0.28
	lamp.height = 0.56
	lamp.radial_segments = 12
	lamp.rings = 6
	_start_material = lights_material(0.0, 1.0, 3.2)
	var lamps := _multimesh(lamp, _start_material, lamp_spots, lamp_colors, gantry)
	lamps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_start_lamps = lamps.multimesh
	set_start_lights("idle")

	# Chase lights: up one pillar, across both edges of the beam and down the other pillar.
	var bulbs: Array[Transform3D] = []
	var phases: Array[Color] = []
	var colors := [Color("#ae63de"), Color("#11bba9")]
	for face in [-1.0, 1.0]:
		var x: float = face * 0.5
		var run := 0.0
		for k in 9:
			bulbs.append(Transform3D(Basis.IDENTITY, Vector3(x, 0.9 + k * 0.62, -post_offset)))
			run += 0.62
			phases.append(bulb_color(colors[k % 2], run))
		var across := int((post_offset * 2.0) / 0.62)
		for k in across + 1:
			bulbs.append(Transform3D(Basis.IDENTITY, Vector3(x, 7.05, -post_offset + k * 0.62)))
			run += 0.62
			phases.append(bulb_color(colors[k % 2], run))
		for k in 9:
			bulbs.append(Transform3D(Basis.IDENTITY, Vector3(x, 0.9 + (8 - k) * 0.62, post_offset)))
			run += 0.62
			phases.append(bulb_color(colors[k % 2], run))
	var bulb := SphereMesh.new()
	bulb.radius = 0.12
	bulb.height = 0.24
	bulb.radial_segments = 8
	bulb.rings = 4
	var chase := _multimesh(bulb, lights_material(0.7, 6.0, 2.6, 0.18), bulbs, phases, gantry)
	chase.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## A solid wedge. `pos` is where the slope meets the ground; the car drives up along `headingDeg`.
func _build_ramp(ramp: Dictionary) -> void:
	var pos: Array = ramp.get("pos", [0, 0])
	var length := float(ramp.get("length", 7.0))
	var half_width := float(ramp.get("width", 6.0)) * 0.5
	var height := length * tan(deg_to_rad(float(ramp.get("angleDeg", 18.0))))
	var heading := deg_to_rad(float(ramp.get("headingDeg", 0.0)))

	var body := StaticBody3D.new()
	body.position = Vector3(float(pos[0]), 0, float(pos[1]))
	body.rotation.y = -heading
	add_child(body)
	var along := Vector2(cos(heading), sin(heading))
	var mid := Vector2(float(pos[0]), float(pos[1])) + along * length * 0.5
	occupied.append(Rect2(mid - Vector2.ONE * (length * 0.5 + 3.0), Vector2.ONE * (length + 6.0)))

	# Local space: +X is the driving direction, low end at x = 0.
	var a0 := Vector3(0, 0, -half_width)
	var a1 := Vector3(0, 0, half_width)
	var b0 := Vector3(length, 0, -half_width)
	var b1 := Vector3(length, 0, half_width)
	var c0 := Vector3(length, height, -half_width)
	var c1 := Vector3(length, height, half_width)

	var shape := CollisionShape3D.new()
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array([a0, a1, b0, b1, c0, c1])
	shape.shape = hull
	body.add_child(shape)

	# The deck: chevrons up the slope and the ramp icon. Lifted a hair off the collision surface.
	var slope := SurfaceTool.new()
	slope.begin(Mesh.PRIMITIVE_TRIANGLES)
	var normal := Vector3(-height, length, 0).normalized()
	var lift := normal * 0.02
	var corners := [a1 + lift, a0 + lift, c0 + lift, c1 + lift]
	var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	var first: Vector3 = corners[0]
	var wound := ((corners[1] as Vector3) - first).cross((corners[2] as Vector3) - first).dot(normal) > 0.0
	for k: int in ([0, 2, 1, 0, 3, 2] if wound else [0, 1, 2, 0, 2, 3]):
		slope.set_normal(normal)
		slope.set_uv(uvs[k])
		slope.add_vertex(corners[k])
	var deck := StandardMaterial3D.new()
	deck.albedo_texture = load(ICON_DIR + "ramp-deck.svg")
	deck.cull_mode = BaseMaterial3D.CULL_DISABLED
	deck.roughness = 0.6
	_add_mesh(slope.commit(), deck, Vector3.ZERO, body)

	# Purple sides with a white top edge, and a dark back face.
	var sides := SurfaceTool.new()
	sides.begin(Mesh.PRIMITIVE_TRIANGLES)
	_quad(sides, b0, b1, c1, c0, COL_BEAM, Vector3.RIGHT)
	for tri: Array in [[a0, b0, c0, Vector3.FORWARD], [a1, b1, c1, Vector3.BACK]]:
		var p: Vector3 = tri[0]
		var q: Vector3 = tri[1]
		var r: Vector3 = tri[2]
		var tri_normal: Vector3 = tri[3]
		for v: Vector3 in ([p, r, q] if (q - p).cross(r - p).dot(tri_normal) > 0.0 else [p, q, r]):
			sides.set_normal(tri_normal)
			sides.set_color(COL_PILLAR)
			sides.add_vertex(v)
	_add_mesh(sides.commit(), _flat_material(), Vector3.ZERO, body)

	# Yellow guard rails along both edges of the slope.
	var slope_length := Vector2(length, height).length()
	var angle := atan2(height, length)
	var frame := body.transform
	for z in [-half_width, half_width]:
		var rail := Transform3D(Basis(Vector3.BACK, angle), Vector3(length * 0.5, height * 0.5 + 0.2, z))
		box_into(_static, frame * rail, Vector3(slope_length, 0.28, 0.22), COL_HAZARD)
		box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(length - 0.15, (height + 0.2) * 0.5, z)), Vector3(0.2, height + 0.2, 0.2), COL_DARK)
	# No floating icon box beside it: from above, one looks just like a boost or bug box.


## A run of concrete blocks with hazard stripes, and a sign facing the camera.
func _build_wall(wall: Dictionary) -> void:
	var from_point: Array = wall.get("from", [0, 0])
	var to_point: Array = wall.get("to", [0, 0])
	var a := Vector2(float(from_point[0]), float(from_point[1]))
	var b := Vector2(float(to_point[0]), float(to_point[1]))
	var height := float(wall.get("height", 1.5))
	var length := a.distance_to(b)
	var mid := (a + b) * 0.5
	var yaw := -atan2(b.y - a.y, b.x - a.x)
	_add_box_body(Vector3(length, height, 1.0), Vector3(mid.x, height * 0.5, mid.y), yaw)
	occupied.append(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(2, 2), (b - a).abs() + Vector2(4, 4)))

	var frame := Transform3D(Basis(Vector3.UP, yaw), Vector3(mid.x, 0, mid.y))
	var blocks := int(ceil(length / 3.0))
	var block_length := length / blocks
	for k in blocks:
		var x := -length * 0.5 + (k + 0.5) * block_length
		box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(x, height * 0.5, 0)), Vector3(block_length - 0.12, height, 1.0), COL_CONCRETE)
		var cap := Vector3(block_length * 0.5 - 0.06, 0.08, 1.02)
		box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(x - block_length * 0.25, height + 0.04, 0)), cap, COL_HAZARD)
		box_into(_static, frame * Transform3D(Basis.IDENTITY, Vector3(x + block_length * 0.25, height + 0.04, 0)), cap, COL_DARK)

	var text := str(wall.get("label", ""))
	if text.is_empty():
		return
	# The end nearer the camera gets the sign.
	var near_end := a if a.y > b.y else b
	var sign_at := Vector3(near_end.x + 2.6, 0, near_end.y + 0.6)
	var board := Transform3D(Basis(Vector3.RIGHT, -0.35), sign_at + Vector3(0, 2.3, 0))
	box_into(_static, board, Vector3(4.6, 1.8, 0.15), COL_HAZARD)
	for side in [-1.6, 1.6]:
		box_into(_static, Transform3D(Basis.IDENTITY, sign_at + Vector3(side, 0.8, -0.1)), Vector3(0.15, 1.6, 0.15), COL_DARK)
	var label := Label3D.new()
	label.text = text
	label.font_size = 64
	label.pixel_size = 0.0105
	label.outline_size = 0
	label.modulate = COL_DARK
	label.line_spacing = -8
	label.transform = board * Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.09))
	add_child(label)


## Armco along both sides of the track wherever there is room, with tyre stacks on the
## outside of the bends. Solid: a car that runs wide bounces off.
func _build_barriers() -> void:
	barriers.clear()
	var half := road_width * 0.5
	var offset := half + BARRIER_GAP
	var count := path.size()
	var rails := SurfaceTool.new()
	rails.begin(Mesh.PRIMITIVE_TRIANGLES)
	var posts: Array[Transform3D] = []
	var tyres: Array[Transform3D] = []
	var tyre_colors: Array[Color] = []
	var body := StaticBody3D.new()
	add_child(body)

	for side in [-1.0, 1.0]:
		var valid := PackedByteArray()
		valid.resize(count)
		var points := PackedVector2Array()
		for i in count:
			var p: Vector2 = path[i] + right_of(tangents[i]) * side * offset
			points.append(p)
			valid[i] = 1 if _barrier_fits(p, offset) else 0

		# Runs of consecutive valid samples, starting after a gap so a run never wraps in two.
		var first_gap := valid.find(0)
		if first_gap == -1:
			first_gap = 0
		var run := PackedInt32Array()
		for k in count + 1:
			var i := (first_gap + k) % count
			if k < count and valid[i] == 1:
				run.append(i)
				continue
			if run.size() >= 4:
				var run_points := PackedVector2Array()
				for index in run:
					run_points.append(points[index])
				barriers.append({"points": run_points, "side": side, "indices": run.duplicate()})
			run = PackedInt32Array()

	for barrier in barriers:
		var run_points: PackedVector2Array = barrier.points
		var indices: PackedInt32Array = barrier.indices
		var side: float = barrier.side
		for k in run_points.size() - 1:
			var p := run_points[k]
			var q := run_points[k + 1]
			_beam(rails, p, q, 0.42, 0.42, 0.16, COL_RAIL, COL_RAIL_SHADE)
			var along := q - p
			var mid := (p + q) * 0.5
			# The collision box reaches a little towards the road so tyre stacks are covered too.
			var inward := -right_of(tangents[indices[k]]) * side * 0.35
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(along.length() + 0.3, 2.6, 1.1)
			shape.shape = box
			shape.position = Vector3(mid.x + inward.x, 1.3, mid.y + inward.y)
			shape.rotation.y = -atan2(along.y, along.x)
			body.add_child(shape)
			if k % 2 == 0:
				posts.append(Transform3D(Basis.IDENTITY, _v(p, 0.4)))
		var last := run_points[run_points.size() - 1]
		posts.append(Transform3D(Basis.IDENTITY, _v(last, 0.4)))

		# Tyre stacks against the barrier on the outside of the tighter bends.
		for k in run_points.size():
			var i := indices[k]
			var outside := -signf(curvature[i])
			if absf(curvature[i]) < SAND_CURVATURE or outside != side or k % 2 == 1:
				continue
			var spot := run_points[k] - right_of(tangents[i]) * side * 0.55
			for level in 3:
				tyres.append(Transform3D(Basis.IDENTITY, _v(spot, 0.16 + level * 0.3)))
				tyre_colors.append(COL_KERB_A if level == 1 and (k / 2) % 2 == 0 else Color(0.12, 0.11, 0.13))

	if barriers.is_empty():
		return

	# Amber marker lights on the posts round the outside of every bend, chasing the way the
	# cars go, so the line through the corner reads from far away.
	var markers: Array[Transform3D] = []
	var marker_phases: Array[Color] = []
	for barrier in barriers:
		var run_points: PackedVector2Array = barrier.points
		var indices: PackedInt32Array = barrier.indices
		var side: float = barrier.side
		for k in range(0, run_points.size(), 2):
			var i := indices[k]
			if absf(curvature[i]) < KERB_CURVATURE or -signf(curvature[i]) != side:
				continue
			markers.append(Transform3D(Basis.IDENTITY, _v(run_points[k], 0.95)))
			marker_phases.append(bulb_color(COL_LAMP_AMBER, float(k) * 1.7))
	if not markers.is_empty():
		var marker := SphereMesh.new()
		marker.radius = 0.17
		marker.height = 0.34
		marker.radial_segments = 8
		marker.rings = 4
		var instance := _multimesh(marker, lights_material(0.9, 5.0, 2.4, 0.2), markers, marker_phases)
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var rails_instance := _add_mesh(rails.commit(), _flat_material())
	rails_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.16, 0.8, 0.16)
	_multimesh(post_mesh, _solid(COL_POST, 0.7), posts)

	if not tyres.is_empty():
		var tyre := TorusMesh.new()
		tyre.inner_radius = 0.2
		tyre.outer_radius = 0.46
		tyre.rings = 12
		tyre.ring_segments = 6
		var tyre_material := StandardMaterial3D.new()
		tyre_material.vertex_color_use_as_albedo = true
		tyre_material.roughness = 0.9
		_multimesh(tyre, tyre_material, tyres, tyre_colors)


## Barriers keep clear of every other part of the road, the shortcut, ramps and walls.
func _barrier_fits(p: Vector2, offset: float) -> bool:
	if absf(p.x) > arena_half.x - 2.0 or absf(p.y) > arena_half.y - 2.0:
		return false
	var limit := (offset - 1.5) * (offset - 1.5)
	for sample in path:
		if p.distance_squared_to(sample) < limit:
			return false
	for shortcut in _shortcuts:
		var points: PackedVector2Array = shortcut.points
		for i in points.size() - 1:
			if _segment_distance_sq(p, points[i], points[i + 1]) < pow(float(shortcut.half) + 4.0, 2):
				return false
	var spot := Rect2(p - Vector2(1, 1), Vector2(2, 2))
	return not is_occupied(spot)


## Little lights set into both edges of the road, pulsing forward round the lap at about the
## speed of a car, like the lights along a runway.
func _build_road_studs() -> void:
	var half := road_width * 0.5
	var count := path.size()
	var studs: Array[Transform3D] = []
	var phases: Array[Color] = []
	var distance := 0.0
	for i in count:
		if i % STUD_EVERY == 0:
			var right := right_of(tangents[i])
			var yaw := -atan2(tangents[i].y, tangents[i].x)
			for side in [-1.0, 1.0]:
				var p: Vector2 = path[i] + right * side * (half - 0.08)
				studs.append(Transform3D(Basis(Vector3.UP, yaw), _v(p, 0.08)))
				phases.append(bulb_color(Color("#3fe0cf"), distance / STUD_WAVE * 10.0))
		distance += path[i].distance_to(path[(i + 1) % count])
	var stud := BoxMesh.new()
	stud.size = Vector3(0.34, 0.06, 0.16)
	var instance := _multimesh(stud, lights_material(0.8, 10.0, 2.2, 0.08), studs, phases)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## The start lights. "idle": a slow amber sweep between runs. "red": `lit` of the five on,
## for the countdown. "green": all green, for GO. "finish": flashing white.
func set_start_lights(mode: String, lit := 0) -> void:
	if not _start_lamps:
		return
	var pattern := mode == "idle" or mode == "finish"
	_start_material.set_shader_parameter("speed", 0.55 if mode == "idle" else (3.0 if mode == "finish" else 0.0))
	_start_material.set_shader_parameter("sharpness", 3.0 if pattern else 1.0)
	for k in START_LAMPS:
		var color := COL_LAMP_OFF
		match mode:
			"idle":
				color = bulb_color(COL_LAMP_AMBER, k * 1.6)
			"red":
				color = COL_LAMP_RED if k < lit else COL_LAMP_OFF
			"green":
				color = COL_LAMP_GREEN
			"finish":
				color = bulb_color(Color.WHITE, 5.0 * (k % 2))
		_start_lamps.set_instance_color(k, color)


## A bulb's instance colour: its colour, with where it sits in the pattern in the alpha.
## `step` is in tenths of a cycle.
static func bulb_color(color: Color, step: float) -> Color:
	return Color(color.r, color.g, color.b, fposmod(step * 0.1, 1.0))


static func lights_material(speed: float, sharpness: float, energy: float, dim := 0.12) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = LIGHTS_SHADER
	material.set_shader_parameter("speed", speed)
	material.set_shader_parameter("sharpness", sharpness)
	material.set_shader_parameter("energy", energy)
	material.set_shader_parameter("dim", dim)
	return material


func _multimesh(mesh: Mesh, material: Material, transforms: Array[Transform3D], colors: Array[Color] = [], parent: Node3D = self) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = not colors.is_empty()
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
		if not colors.is_empty():
			multimesh.set_instance_color(i, colors[i])
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.material_override = material
	parent.add_child(instance)
	return instance


func _add_pickup(kind: String, item: Dictionary) -> void:
	var at := float(item.get("at", 0.0))
	var center := point_at(at) + right_of(tangent_at(at)) * float(item.get("offset", 0.0))
	var pickup := Pickup.new()
	pickup.kind = kind
	pickup.position = Vector3(center.x, 0, center.y)
	add_child(pickup)


static func _v(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x, y, p.y)
