extends Node3D
## Everything around the track that is only there to look at: mown grass, hills outside the
## arena, trees, bushes and rocks (Kenney Nature Kit, CC0), a grandstand with marquee lights,
## team tents, Bitrise flags, banners and billboards, and crowds that cheer when a car comes past.
##
## The game camera looks north (towards -Z) from high up, so anything tall standing south of
## the road would hide it. Placement checks for that, see _blocks_view().

## A crowd has just got excited about a car going past. `strength` 0 to 1: how close it came.
signal cheered(strength: float)

const Models := preload("res://scripts/models.gd")
const Track := preload("res://scripts/track.gd")
const GROUND_SHADER := preload("res://shaders/ground.gdshader")
const CROWD_SHADER := preload("res://shaders/crowd.gdshader")
const FLAG_SHADER := preload("res://shaders/flag.gdshader")
const ICON_DIR := "res://assets/icons/"

## How far the hills reach beyond the arena.
const HILL_MARGIN := 72.0
## A crowd cheers out loud at most this often, in seconds.
const CHEER_COOLDOWN := 4.0
const TERRAIN_CELL := 4.0
## Ground hidden behind something of height h, seen from the game camera: about 0.73 h.
const VIEW_SHADOW := 0.75
const SECTOR := 64.0
const BUCKET := 16.0

const COL_WOOD := Color("#8a6a4a")
const COL_CONCRETE := Color("#cdc7d5")
const COL_SEAT := Color("#7b3ba5")
const COL_PURPLE := Color("#6c2fa0")
const COL_DEEP := Color("#2b0e3f")
const COL_TEAL := Color("#11bba9")
const COL_WHITE := Color("#f6f4f6")
const COL_YELLOW := Color("#f9cc15")
const SHIRTS := [
	Color("#9247c2"), Color("#11bba9"), Color("#f9cc15"), Color("#f7596c"), Color("#4f9bde"),
	Color("#f6f4f6"), Color("#fd9730"), Color("#2b0e3f"), Color("#4eb76c"), Color("#ae63de"),
]
## Bitrise and its product lines, round the track on the Armco.
const BANNERS := ["BITRISE", "BUILD CACHE", "MOBILE CI/CD", "INSIGHTS", "RELEASE MANAGEMENT", "CODEPUSH", "BITRISE RDE", "BUILD HUB"]
const FLAG_ICONS := ["badge-bitrise", "bitbot", "ci", "build-hub", "code-push", "insights", "rde"]

## 1 for the big screen and desktops, lower on phones: fewer trees and spectators.
var detail := 1.0

var _track: Track
var _rng := RandomNumberGenerator.new()
var _noise := FastNoiseLite.new()
var _buckets: Dictionary = {}
var _taken: Array[Rect2] = []
var _tree_spots: Dictionary = {}
var _crowds: Array[Dictionary] = []
var _person: ArrayMesh
## Posts, boards and poles merged into one mesh, and trees, bushes and rocks merged into one
## mesh per map sector: a few draw calls instead of hundreds, which phones care about.
var _static: SurfaceTool
var _baked: Dictionary = {}


func build(track: Track) -> void:
	_track = track
	_rng.seed = hash(track.track_id)
	_noise.seed = _rng.randi()
	_noise.frequency = 0.018
	_index_road()
	_person = _person_mesh()
	_static = SurfaceTool.new()
	_static.begin(Mesh.PRIMITIVE_TRIANGLES)

	_build_terrain()
	_build_fence()
	_build_grandstand()
	_build_billboards()
	_build_banners()
	_build_trackside_crowds()
	_build_flags()
	_build_trees()

	var solid := _vertex_material()
	solid.roughness = 0.75
	_add_mesh(_static.commit(), solid, Vector3.ZERO)
	for key: Vector2i in _baked:
		var nature := _vertex_material()
		nature.roughness = 0.9
		_add_mesh((_baked[key] as SurfaceTool).commit(), nature, Vector3.ZERO)


## Crowds cheer for whatever is near them: the player's car on a phone, everyone on the big screen.
func update_focus(points: Array[Vector3], delta: float) -> void:
	for crowd in _crowds:
		var center: Vector2 = crowd.center
		var nearest := INF
		for point in points:
			nearest = minf(nearest, center.distance_to(Vector2(point.x, point.z)))
		var target := clampf(1.0 - (nearest - float(crowd.radius)) / 30.0, 0.0, 1.0)
		var value: float = crowd.excite
		value = lerpf(value, target, 1.0 - exp(-3.0 * delta))
		crowd.cooldown = maxf(0.0, float(crowd.cooldown) - delta)
		if value > 0.55 and float(crowd.excite) <= 0.55 and crowd.cooldown <= 0.0:
			crowd.cooldown = CHEER_COOLDOWN
			cheered.emit(target)
		if absf(value - float(crowd.excite)) > 0.01:
			crowd.excite = value
			(crowd.material as ShaderMaterial).set_shader_parameter("excite", value)


# --- placement helpers ----------------------------------------------------------------------------

func _index_road() -> void:
	_buckets.clear()
	for i in _track.path.size():
		var key := _bucket_of(_track.path[i])
		if not _buckets.has(key):
			_buckets[key] = PackedInt32Array()
		var list: PackedInt32Array = _buckets[key]
		list.append(i)
		_buckets[key] = list


func _bucket_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / BUCKET), floori(p.y / BUCKET))


## Centreline samples within `radius` of `p` (or a bit more).
func _samples_near(p: Vector2, radius: float) -> PackedInt32Array:
	var found := PackedInt32Array()
	var reach := ceili(radius / BUCKET)
	var home := _bucket_of(p)
	for dx in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			var key := home + Vector2i(dx, dz)
			if _buckets.has(key):
				found.append_array(_buckets[key])
	return found


## Approximate distance from `p` to the edge of the road (negative on it), capped at 40.
func _road_clearance(p: Vector2) -> float:
	var half := _track.road_width * 0.5
	var best := 40.0 + half
	for i in _samples_near(p, 40.0):
		best = minf(best, p.distance_to(_track.path[i]))
	var result := best - half
	# The shortcut is narrow and rare; check it exactly.
	if result > 0.0:
		result = minf(result, _track.distance_to_road(p)) if _near_shortcut(p) else result
	return result


func _near_shortcut(p: Vector2) -> bool:
	for shortcut: Dictionary in _track.data.get("shortcuts", []):
		for point: Array in shortcut.get("points", []):
			if p.distance_to(Vector2(float(point[0]), float(point[1]))) < 80.0:
				return true
	return false


## True if something `height` tall and `radius` wide at `p` would hide part of the road from
## the game camera, which looks north from the south.
func _blocks_view(p: Vector2, height: float, radius: float) -> bool:
	var half := _track.road_width * 0.5
	var depth := height * VIEW_SHADOW
	for i in _samples_near(p, depth + half + radius + 2.0):
		var s := _track.path[i]
		if absf(s.x - p.x) < radius + half + 0.5 and s.y < p.y + radius + half and s.y > p.y - depth - half:
			return true
	return false


func _is_free(rect: Rect2) -> bool:
	if _track.is_occupied(rect):
		return false
	for taken in _taken:
		if taken.intersects(rect):
			return false
	return true


func _take(rect: Rect2) -> void:
	_taken.append(rect)


func _in_arena(p: Vector2, margin: float) -> bool:
	return absf(p.x) < _track.arena_half.x - margin and absf(p.y) < _track.arena_half.y - margin


func _hill_height(x: float, z: float) -> float:
	var dx := maxf(absf(x) - (_track.arena_half.x + 3.0), 0.0)
	var dz := maxf(absf(z) - (_track.arena_half.y + 3.0), 0.0)
	var d := sqrt(dx * dx + dz * dz)
	if d <= 0.0:
		return 0.0
	var n := _noise.get_noise_2d(x, z) * 0.5 + 0.5
	return smoothstep(0.0, 30.0, d) * (3.0 + 16.0 * n)


static func _vertex_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.85
	return material


func _add_mesh(mesh: Mesh, material: Material, at: Vector3, parent: Node3D = self) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	return instance


## Adds an axis-aligned box to a SurfaceTool. `tag` (UV.x) marks body parts for the crowd
## shader; `wave` (UV.y) marks the top face so hands can wave.
static func _box(st: SurfaceTool, center: Vector3, size: Vector3, color: Color, tag := 1.0, wave := false) -> void:
	var h := size * 0.5
	var faces := [
		[Vector3.UP, [Vector3(-1, 1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]],
		[Vector3.DOWN, [Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, -1, -1), Vector3(-1, -1, -1)]],
		[Vector3.FORWARD, [Vector3(1, -1, -1), Vector3(-1, -1, -1), Vector3(-1, 1, -1), Vector3(1, 1, -1)]],
		[Vector3.BACK, [Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]],
		[Vector3.LEFT, [Vector3(-1, -1, -1), Vector3(-1, -1, 1), Vector3(-1, 1, 1), Vector3(-1, 1, -1)]],
		[Vector3.RIGHT, [Vector3(1, -1, 1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1)]],
	]
	for face: Array in faces:
		var normal: Vector3 = face[0]
		var corners: Array = face[1]
		var a: Vector3 = corners[0]
		var b: Vector3 = corners[1]
		var c: Vector3 = corners[2]
		# Godot treats clockwise triangles as front faces.
		var order := [0, 2, 1, 0, 3, 2] if (b - a).cross(c - a).dot(normal) > 0.0 else [0, 1, 2, 0, 2, 3]
		for k: int in order:
			var corner: Vector3 = corners[k]
			st.set_normal(normal)
			st.set_color(color)
			st.set_uv(Vector2(tag, 1.0 if wave and corner.y > 0.0 else 0.0))
			st.add_vertex(center + corner * h)


## Merges copies of a (vertex-coloured) mesh into one mesh per map sector.
func _bake(mesh: Mesh, transforms: Array[Transform3D]) -> void:
	for transform in transforms:
		var key := Vector2i(floori(transform.origin.x / SECTOR), floori(transform.origin.z / SECTOR))
		if not _baked.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			_baked[key] = st
		(_baked[key] as SurfaceTool).append_from(mesh, 0, transform)


## Splits instances into map sectors, one MultiMesh each, so the camera can skip far ones.
func _scatter(mesh: Mesh, transforms: Array[Transform3D], material: Material = null, shadows := true) -> void:
	var sectors: Dictionary = {}
	for transform in transforms:
		var key := Vector2i(floori(transform.origin.x / SECTOR), floori(transform.origin.z / SECTOR))
		if not sectors.has(key):
			sectors[key] = []
		(sectors[key] as Array).append(transform)
	for key: Vector2i in sectors:
		var list: Array = sectors[key]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = list.size()
		for i in list.size():
			multimesh.set_instance_transform(i, list[i])
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = multimesh
		if material:
			instance.material_override = material
		if not shadows:
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)


# --- ground -----------------------------------------------------------------------------------------

func _build_terrain() -> void:
	var half := _track.arena_half + Vector2(HILL_MARGIN, HILL_MARGIN)
	var columns := int(ceil(half.x * 2.0 / TERRAIN_CELL))
	var rows := int(ceil(half.y * 2.0 / TERRAIN_CELL))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row in rows + 1:
		for column in columns + 1:
			var x := -half.x + column * TERRAIN_CELL
			var z := -half.y + row * TERRAIN_CELL
			st.set_uv(Vector2(x, z))
			st.add_vertex(Vector3(x, _hill_height(x, z), z))
	for row in rows:
		for column in columns:
			var a := row * (columns + 1) + column
			var b := a + 1
			var c := a + columns + 1
			var d := c + 1
			for index in [a, b, d, a, d, c]:
				st.add_index(index)
	st.generate_normals()
	var material := ShaderMaterial.new()
	material.shader = GROUND_SHADER
	var instance := _add_mesh(st.commit(), material, Vector3.ZERO)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## A low wooden fence round the arena, where the invisible walls are.
func _build_fence() -> void:
	var half := _track.arena_half + Vector2(1.0, 1.0)
	var posts: Array[Transform3D] = []
	var rails := SurfaceTool.new()
	rails.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]
	for k in 4:
		var a: Vector2 = corners[k]
		var b: Vector2 = corners[(k + 1) % 4]
		var length := a.distance_to(b)
		var steps := int(length / 4.0)
		for s in steps:
			var p := a.lerp(b, float(s) / steps)
			posts.append(Transform3D(Basis.IDENTITY, Vector3(p.x, 0.55, p.y)))
		var mid := (a + b) * 0.5
		var along := (b - a).normalized()
		for height in [0.45, 0.85]:
			var size := Vector3(length if absf(along.x) > 0.5 else 0.1, 0.12, length if absf(along.y) > 0.5 else 0.1)
			_box(rails, Vector3(mid.x, height, mid.y), size, COL_WOOD, 0.0)
	_add_mesh(rails.commit(), _vertex_material(), Vector3.ZERO)
	for post in posts:
		Track.box_into(_static, post, Vector3(0.18, 1.1, 0.18), COL_WOOD.darkened(0.2))


# --- stands, tents, flags ---------------------------------------------------------------------------

## A grandstand on the north side of a straight (so it faces the road and the camera), as
## close to the finish line as there is room for, with team tents at both ends.
func _build_grandstand() -> void:
	var half := _track.road_width * 0.5
	var depth := 5.0
	var front := half + Track.BARRIER_GAP + 1.2
	var count := _track.path.size()
	# Samples ordered by how far they are from the finish line, either way round.
	var order := range(count)
	order.sort_custom(func(a: int, b: int) -> bool: return mini(a, count - a) < mini(b, count - b))
	for width in [30.0, 24.0, 18.0]:
		for i: int in order:
			var tangent := _track.tangents[i]
			var normal := Track.right_of(tangent)
			if normal.y > 0.0:
				normal = -normal
			# North of the road, along a straight that runs roughly east-west.
			if normal.y > -0.8 or absf(_track.curvature[i]) > 0.01:
				continue
			var center := _track.path[i] + normal * (front + depth * 0.5)
			var rect := _rotated_rect(center, tangent, width, depth)
			if not _in_arena(center, depth * 0.5 + 1.5) or not _in_arena(center + tangent * width * 0.5, 1.5) \
					or not _in_arena(center - tangent * width * 0.5, 1.5):
				continue
			if not _is_free(rect) or not _footprint_clear(center, tangent, normal, width, depth, Track.BARRIER_GAP + 0.5):
				continue
			if _crosses_barrier(rect):
				continue
			_take(rect)
			_grandstand(center, tangent, normal, width, depth)
			_build_tents(_track.path[i], tangent, normal, width, front)
			return


## True when any Armco runs through `rect`.
func _crosses_barrier(rect: Rect2) -> bool:
	var grown := rect.grow(0.3)
	for barrier in _track.barriers:
		for point in (barrier.points as PackedVector2Array):
			if grown.has_point(point):
				return true
	return false


## The bounding box of a width x depth rectangle centred on `center`, its width along `along`.
static func _rotated_rect(center: Vector2, along: Vector2, width: float, depth: float) -> Rect2:
	var side := Vector2(-along.y, along.x)
	var extent := (along * width * 0.5).abs() + (side * depth * 0.5).abs()
	return Rect2(center - extent, extent * 2.0)


func _footprint_clear(center: Vector2, along: Vector2, normal: Vector2, width: float, depth: float, clearance: float) -> bool:
	for u in [-0.5, -0.25, 0.0, 0.25, 0.5]:
		for v in [-0.5, 0.0, 0.5]:
			var p: Vector2 = center + along * width * u + normal * depth * v
			if _road_clearance(p) < clearance:
				return false
	return true


func _grandstand(center: Vector2, along: Vector2, normal: Vector2, width: float, depth: float) -> void:
	var stand := Node3D.new()
	stand.position = Vector3(center.x, 0, center.y)
	# Local +Z faces the road (away from `normal`), local +X runs along the straight.
	var facing := -normal
	stand.rotation.y = atan2(facing.x, facing.y)
	add_child(stand)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tiers := clampi(int((depth - 1.0) / 1.3), 2, 4)
	var tier_depth := (depth - 1.0) / tiers
	var seated: Array[Transform3D] = []
	var shirts: Array[Color] = []
	for k in tiers:
		var height := 0.9 + k * 0.8
		var z := depth * 0.5 - 0.6 - (k + 0.5) * tier_depth
		_box(st, Vector3(0, height * 0.5, z), Vector3(width, height, tier_depth), COL_CONCRETE, 0.0)
		_box(st, Vector3(0, height + 0.05, z - tier_depth * 0.25), Vector3(width - 0.4, 0.1, tier_depth * 0.35), COL_SEAT, 0.0)
		var spacing := 0.8 / sqrt(detail)
		var count := int((width - 1.5) / spacing)
		for s in count:
			if _rng.randf() < 0.15:
				continue
			var x := -width * 0.5 + 0.9 + s * spacing + _rng.randf_range(-0.15, 0.15)
			var basis := Basis.IDENTITY.scaled(Vector3.ONE * _rng.randf_range(0.85, 1.0))
			seated.append(Transform3D(basis, Vector3(x, height - 0.35, z + 0.15)))
	# Back wall and end walls in Bitrise purple, a canopy over the top rows.
	_box(st, Vector3(0, 2.6, -depth * 0.5 + 0.3), Vector3(width + 0.6, 5.2, 0.6), COL_PURPLE, 0.0)
	for side in [-1.0, 1.0]:
		_box(st, Vector3(side * (width * 0.5 + 0.3), 1.9, 0), Vector3(0.6, 3.8, depth), COL_PURPLE, 0.0)
	_box(st, Vector3(0, 5.5, -depth * 0.5 + 1.4), Vector3(width + 1.0, 0.25, 2.8), COL_DEEP, 0.0)
	_box(st, Vector3(0, 0.5, depth * 0.5 - 0.3), Vector3(width, 1.0, 0.3), COL_WHITE, 0.0)
	_add_mesh(st.commit(), _vertex_material(), Vector3.ZERO, stand)

	var fascia := Label3D.new()
	fascia.text = "BITRISE  ·  GRAND PRIX"
	fascia.font_size = 96
	fascia.pixel_size = 0.0125
	fascia.modulate = COL_DEEP
	fascia.outline_size = 0
	fascia.position = Vector3(0, 0.55, depth * 0.5 - 0.13)
	stand.add_child(fascia)

	_add_crowd(seated, center, width * 0.5, stand)

	# Marquee bulbs along the front of the canopy, chasing in Bitrise yellow and white.
	var bulbs: Array[Transform3D] = []
	var phases: Array[Color] = []
	var bulb_count := int((width + 0.6) / 0.7)
	for k in bulb_count + 1:
		var x := -(width + 0.6) * 0.5 + k * 0.7
		bulbs.append(Transform3D(Basis.IDENTITY, Vector3(x, 5.5, -depth * 0.5 + 2.83)))
		phases.append(Track.bulb_color(COL_YELLOW if k % 2 == 0 else COL_WHITE, k * 0.9))
	var bulb := SphereMesh.new()
	bulb.radius = 0.13
	bulb.height = 0.26
	bulb.radial_segments = 8
	bulb.rings = 4
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = bulb
	multimesh.instance_count = bulbs.size()
	for i in bulbs.size():
		multimesh.set_instance_transform(i, bulbs[i])
		multimesh.set_instance_color(i, phases[i])
	var lights := MultiMeshInstance3D.new()
	lights.multimesh = multimesh
	lights.material_override = Track.lights_material(0.45, 2.5, 2.4, 0.25)
	lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stand.add_child(lights)


## Pop-up team tents at both ends of the grandstand, with cones and a few people.
func _build_tents(road_point: Vector2, along: Vector2, normal: Vector2, stand_width: float, front: float) -> void:
	var center := road_point + normal * front
	var spots: Array[Vector2] = []
	for side in [-1.0, 1.0]:
		for k in 2:
			spots.append(road_point + along * side * (stand_width * 0.5 + 3.5 + k * 4.6) + normal * (front + 2.5))
	var colors := [COL_PURPLE, COL_TEAL, COL_PURPLE, COL_TEAL]
	var people: Array[Transform3D] = []
	var cones: Array[Transform3D] = []
	for i in spots.size():
		var spot := spots[i]
		var rect := Rect2(spot - Vector2(2.2, 2.2), Vector2(4.4, 4.4))
		if not _in_arena(spot, 3.0) or not _is_free(rect) or _road_clearance(spot) < Track.BARRIER_GAP + 0.5 or _crosses_barrier(rect):
			continue
		if _blocks_view(spot, 3.5, 2.0):
			continue
		_take(rect)
		_tent(spot, colors[i], along)
		for p in 3:
			var at := spot + Vector2(_rng.randf_range(-1.3, 1.3), _rng.randf_range(-1.3, 1.3))
			people.append(Transform3D(Basis(Vector3.UP, _rng.randf_range(0, TAU)), Vector3(at.x, 0, at.y)))
		var cone_at := spot - normal * 2.6
		cones.append(Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 1.6), Vector3(cone_at.x, 0, cone_at.y)))
	if not people.is_empty():
		_add_crowd(people, center, stand_width * 0.5 + 10.0, self)
	if not cones.is_empty():
		_scatter(Models.kit_mesh("cone"), cones)


func _tent(spot: Vector2, color: Color, along: Vector2) -> void:
	var tent := Node3D.new()
	tent.position = Vector3(spot.x, 0, spot.y)
	tent.rotation.y = -atan2(along.y, along.x)
	add_child(tent)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size := 3.4
	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			_box(st, Vector3(x * size * 0.5, 1.25, z * size * 0.5), Vector3(0.08, 2.5, 0.08), Color("#c9c1cd"), 0.0)
	# Valance band round the edge of the roof, white and the tent colour.
	_box(st, Vector3(0, 2.4, 0), Vector3(size + 0.1, 0.3, size + 0.1), COL_WHITE, 0.0)
	_box(st, Vector3(0, 0.45, 0), Vector3(1.8, 0.08, 0.7), COL_WHITE, 0.0)
	_box(st, Vector3(0, 0.22, 0), Vector3(1.7, 0.44, 0.06), Color("#c9c1cd"), 0.0)
	var roof := [Vector3(-size * 0.5, 2.55, -size * 0.5), Vector3(size * 0.5, 2.55, -size * 0.5),
		Vector3(size * 0.5, 2.55, size * 0.5), Vector3(-size * 0.5, 2.55, size * 0.5)]
	var peak := Vector3(0, 3.5, 0)
	for k in 4:
		var a: Vector3 = roof[k]
		var b: Vector3 = roof[(k + 1) % 4]
		var normal := (b - a).cross(peak - a).normalized()
		if normal.y < 0.0:
			normal = -normal
		var shade := color if k % 2 == 0 else color.lightened(0.15)
		var points := [a, b, peak] if (b - a).cross(peak - a).dot(normal) < 0.0 else [a, peak, b]
		for v: Vector3 in points:
			st.set_normal(normal)
			st.set_color(Color(shade.r, shade.g, shade.b, 0.0))
			st.add_vertex(v)
	var material := _vertex_material()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_add_mesh(st.commit(), material, Vector3.ZERO, tent)


## Feather flags along the start straight and beside the tents.
func _build_flags() -> void:
	var half := _track.road_width * 0.5
	var n_control := float((_track.data.get("centerline", []) as Array).size())
	var index := 0
	for k in range(-6, 7):
		var at := fposmod(k * 0.18, n_control)
		var normal := Track.right_of(_track.tangent_at(at))
		for side in [-1.0, 1.0]:
			if posmod(k, 2) == (0 if side > 0.0 else 1):
				continue
			var p: Vector2 = _track.point_at(at) + normal * side * (half + Track.BARRIER_GAP + 2.2)
			var rect := Rect2(p - Vector2(1, 1), Vector2(2, 2))
			if not _in_arena(p, 2.0) or not _is_free(rect) or _road_clearance(p) < Track.BARRIER_GAP + 1.0:
				continue
			if _blocks_view(p, 5.5, 1.0):
				continue
			_take(rect)
			_flag(p, index)
			index += 1


func _flag(p: Vector2, index: int) -> void:
	var holder := Node3D.new()
	holder.position = Vector3(p.x, 0, p.y)
	add_child(holder)
	Track.box_into(_static, Transform3D(Basis.IDENTITY, Vector3(p.x, 3.0, p.y)), Vector3(0.12, 6.0, 0.12), Color("#c9c1cd"))

	var cloth := QuadMesh.new()
	cloth.size = Vector2(1.5, 4.4)
	cloth.subdivide_width = 6
	cloth.subdivide_depth = 12
	var material := ShaderMaterial.new()
	material.shader = FLAG_SHADER
	var icon: String = FLAG_ICONS[index % FLAG_ICONS.size()]
	material.set_shader_parameter("icon", load(ICON_DIR + icon + ".svg"))
	material.set_shader_parameter("base", COL_PURPLE if index % 2 == 0 else COL_DEEP)
	material.set_shader_parameter("trim", COL_TEAL if index % 3 == 0 else COL_WHITE)
	material.set_shader_parameter("phase", index * 1.7)
	material.set_shader_parameter("aspect", 4.4 / 1.5)
	# The quad hangs from the pole's top, facing the camera (+Z).
	_add_mesh(cloth, material, Vector3(0.78, 3.7, 0), holder)


## The track file's billboards, turned to face the camera and moved across the road if they
## would hide it.
func _build_billboards() -> void:
	for board: Dictionary in _track.data.get("billboards", []):
		var at := float(board.get("at", 0.0))
		var normal := Track.right_of(_track.tangent_at(at))
		var offset := float(board.get("offset", 12.0))
		for candidate in [offset, -offset, offset + 4.0, -offset - 4.0]:
			var p := _track.point_at(at) + normal * float(candidate)
			p.x = clampf(p.x, -_track.arena_half.x + 6.0, _track.arena_half.x - 6.0)
			p.y = clampf(p.y, -_track.arena_half.y + 4.0, _track.arena_half.y - 4.0)
			var rect := Rect2(p - Vector2(5, 1.5), Vector2(10, 3))
			if _road_clearance(p) < Track.BARRIER_GAP + 1.0 or not _is_free(rect) or _blocks_view(p, 6.5, 4.6):
				continue
			_take(rect)
			_billboard(p, board)
			break


func _billboard(p: Vector2, board: Dictionary) -> void:
	var root := Node3D.new()
	root.position = Vector3(p.x, 0, p.y)
	add_child(root)
	var width := 9.0
	var height := 3.8
	for side in [-1.0, 1.0]:
		Track.box_into(_static, root.transform * Transform3D(Basis.IDENTITY, Vector3(side * width * 0.35, 1.5, -0.3)), Vector3(0.3, 3.0, 0.3), COL_DEEP)

	var panel := Node3D.new()
	panel.position = Vector3(0, 3.0 + height * 0.5, 0)
	# Lean back so the face is readable from the high camera.
	panel.rotation.x = -deg_to_rad(28.0)
	root.add_child(panel)
	var face := root.transform * panel.transform
	Track.box_into(_static, face * Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.05)), Vector3(width + 0.4, height + 0.4, 0.3), COL_WHITE)
	Track.box_into(_static, face, Vector3(width, height, 0.3), COL_DEEP)

	var image_path := str(board.get("image", ""))
	if not image_path.is_empty() and ResourceLoader.exists(image_path):
		var art := QuadMesh.new()
		art.size = Vector2(width - 0.3, height - 0.3)
		var art_material := StandardMaterial3D.new()
		art_material.albedo_texture = load(image_path)
		art_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_add_mesh(art, art_material, Vector3(0, 0, 0.17), panel)
		return

	var icon := QuadMesh.new()
	icon.size = Vector2(height - 0.6, height - 0.6)
	var icon_material := StandardMaterial3D.new()
	icon_material.albedo_texture = load(ICON_DIR + str(board.get("icon", "badge-bitrise")) + ".svg")
	icon_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_add_mesh(icon, icon_material, Vector3(-width * 0.5 + height * 0.5, 0, 0.17), panel)

	var label := Label3D.new()
	label.text = str(board.get("text", ""))
	label.font_size = 72
	label.pixel_size = 0.0085
	label.outline_size = 0
	label.line_spacing = -6
	label.modulate = COL_WHITE
	label.width = 560
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.position = Vector3(height * 0.5 - 0.2, 0, 0.17)
	panel.add_child(label)


## Advertising boards behind the barriers north of the road, where they face the camera.
func _build_banners() -> void:
	var index := 0
	for barrier in _track.barriers:
		var points: PackedVector2Array = barrier.points
		var indices: PackedInt32Array = barrier.indices
		var side: float = barrier.side
		var run_length := 0.0
		var k := 0
		while k < points.size() - 3:
			var i := indices[k]
			var outward := Track.right_of(_track.tangents[i]) * side
			var a := points[k]
			var b := points[k + 3]
			var along := (b - a).normalized()
			if outward.y > -0.6 or absf(along.x) < 0.75:
				k += 1
				continue
			run_length += 1.0
			if int(run_length) % 2 == 0:
				k += 3
				continue
			var mid := (a + b) * 0.5 + outward * 0.7
			var rect := Rect2(mid - Vector2(3.5, 1.0), Vector2(7, 2))
			if _is_free(rect):
				_take(rect)
				_banner(mid, along if along.x > 0.0 else -along, a.distance_to(b), index)
				index += 1
			k += 3


func _banner(mid: Vector2, along: Vector2, length: float, index: int) -> void:
	var holder := Node3D.new()
	holder.position = Vector3(mid.x, 0, mid.y)
	holder.rotation.y = atan2(-along.y, along.x)
	add_child(holder)
	var palettes := [[COL_PURPLE, COL_WHITE], [COL_WHITE, COL_PURPLE], [COL_TEAL, COL_DEEP], [COL_DEEP, COL_YELLOW]]
	var palette: Array = palettes[index % palettes.size()]
	var board := Node3D.new()
	board.position = Vector3(0, 0.95, 0)
	board.rotation.x = -deg_to_rad(30.0)
	holder.add_child(board)
	Track.box_into(_static, holder.transform * board.transform, Vector3(length - 0.3, 1.1, 0.12), palette[0])
	var label := Label3D.new()
	label.text = BANNERS[index % BANNERS.size()]
	label.font_size = 96
	label.pixel_size = 0.0095
	label.outline_size = 0
	label.modulate = palette[1]
	label.position = Vector3(0, 0, 0.07)
	board.add_child(label)
	for x in [-length * 0.4, length * 0.4]:
		Track.box_into(_static, holder.transform * Transform3D(Basis.IDENTITY, Vector3(x, 0.45, -0.25)), Vector3(0.1, 0.9, 0.1), COL_DEEP)


# --- people -----------------------------------------------------------------------------------------

## One spectator, about 1.8 tall, arms up. UV.x tags the parts for crowd.gdshader.
func _person_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(0, 0.42, 0), Vector3(0.38, 0.84, 0.24), Color.WHITE, 0.0)
	_box(st, Vector3(0, 1.15, 0), Vector3(0.52, 0.64, 0.3), Color.WHITE, 1.0)
	_box(st, Vector3(0, 1.64, 0), Vector3(0.3, 0.32, 0.3), Color.WHITE, 0.5)
	_box(st, Vector3(0, 1.83, 0), Vector3(0.32, 0.08, 0.32), Color.WHITE, 0.25)
	for side in [-1.0, 1.0]:
		_box(st, Vector3(side * 0.33, 1.6, 0), Vector3(0.13, 0.55, 0.13), Color.WHITE, 1.0, true)
	return st.commit()


## Adds a group of spectators that share one excitement level, centred on `center`.
func _add_crowd(transforms: Array[Transform3D], center: Vector2, radius: float, parent: Node3D) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _person
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
		multimesh.set_instance_color(i, SHIRTS[_rng.randi() % SHIRTS.size()])
	var material := ShaderMaterial.new()
	material.shader = CROWD_SHADER
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.material_override = material
	parent.add_child(instance)
	_crowds.append({"center": center, "radius": radius, "material": material, "excite": 0.0, "cooldown": 0.0})


## Spectators standing behind the barrier on the outside of the tightest bends.
func _build_trackside_crowds() -> void:
	var half := _track.road_width * 0.5
	var spots: Array = []
	var count := _track.path.size()
	# The tightest bends first, at least 40 samples apart.
	var order := range(count)
	order.sort_custom(func(a: int, b: int) -> bool: return absf(_track.curvature[a]) > absf(_track.curvature[b]))
	for i: int in order:
		if absf(_track.curvature[i]) < Track.SAND_CURVATURE or spots.size() >= 5:
			break
		var far_enough := true
		for spot: int in spots:
			var gap := absi(spot - i)
			if mini(gap, count - gap) < 40:
				far_enough = false
		if far_enough:
			spots.append(i)

	for i: int in spots:
		var outside := -signf(_track.curvature[i])
		var people: Array[Transform3D] = []
		for k in range(-10, 11):
			var j := posmod(i + k, count)
			var normal := Track.right_of(_track.tangents[j]) * outside
			for row in 3:
				if _rng.randf() > 0.75 * detail + 0.1:
					continue
				var distance := half + Track.BARRIER_GAP + 1.4 + row * 1.1 + _rng.randf_range(-0.2, 0.2)
				var p := _track.path[j] + normal * distance + _track.tangents[j] * _rng.randf_range(-0.6, 0.6)
				if not _in_arena(p, 1.5) or _road_clearance(p) < Track.BARRIER_GAP + 1.0:
					continue
				if not _is_free(Rect2(p - Vector2(0.4, 0.4), Vector2(0.8, 0.8))):
					continue
				var facing := -normal
				var basis := Basis(Vector3.UP, atan2(facing.x, facing.y)).scaled(Vector3.ONE * _rng.randf_range(0.85, 1.05))
				people.append(Transform3D(basis, Vector3(p.x, 0, p.y)))
		if people.size() < 8:
			continue
		var center := _track.path[i] + Track.right_of(_track.tangents[i]) * outside * (half + Track.BARRIER_GAP + 2.5)
		_take(Rect2(center - Vector2(12, 12), Vector2(24, 24)))
		_add_crowd(people, center, 14.0, self)


# --- trees, bushes, rocks ---------------------------------------------------------------------------

func _build_trees() -> void:
	var pines := ["tree_pineTallA_detailed", "tree_pineTallB_detailed", "tree_pineRoundA", "tree_pineRoundC", "tree_pineDefaultA"]
	var leafy := ["tree_default", "tree_oak", "tree_detailed"]
	var purple := {"leafsGreen": Color("#a465d6"), "leafsDark": Color("#8a4fc0")}
	var kinds: Array = []
	for model in pines:
		kinds.append({"model": model, "colors": {}, "weight": 3.0, "scale": Vector2(6.5, 8.5), "height": 10.0})
	for model in leafy:
		kinds.append({"model": model, "colors": {}, "weight": 2.0, "scale": Vector2(5.5, 7.0), "height": 9.0})
	# Bitrise-purple jacarandas, a few here and there.
	kinds.append({"model": "tree_default", "colors": purple, "weight": 1.6, "scale": Vector2(5.5, 6.5), "height": 9.0})
	kinds.append({"model": "tree_oak", "colors": purple, "weight": 1.0, "scale": Vector2(5.5, 6.5), "height": 8.0})

	var placed: Dictionary = {}
	var inside := int(700 * detail)
	var outside := int(900 * detail)
	for attempt in inside + outside:
		var on_hills := attempt >= inside
		var p := _random_spot(on_hills)
		# Clumps rather than an even sprinkle.
		if _noise.get_noise_2d(p.x * 2.3, p.y * 2.3) < (-0.05 if on_hills else 0.12):
			continue
		var kind: Dictionary = _pick(kinds)
		var scale := _rng.randf_range(kind.scale.x, kind.scale.y)
		var height := float(kind.height) * scale / 7.0
		if not _tree_fits(p, on_hills, height, 2.4):
			continue
		_remember_tree(p)
		var key := str(kind.model) + str(kind.colors)
		if not placed.has(key):
			var fresh: Array[Transform3D] = []
			placed[key] = {"mesh": Models.baked_mesh(kind.model, kind.colors), "list": fresh}
		var list: Array[Transform3D] = placed[key].list
		var basis := Basis(Vector3.UP, _rng.randf_range(0, TAU)).scaled(Vector3.ONE * scale)
		list.append(Transform3D(basis, Vector3(p.x, _hill_height(p.x, p.y) - 0.1, p.y)))
	for key: String in placed:
		var entry: Dictionary = placed[key]
		_bake(entry.mesh, entry.list)

	_scatter_small(["plant_bushLarge", "plant_bush"], int(260 * detail), Vector2(6.0, 9.0), 1.2)
	_scatter_small(["rock_largeA", "rock_largeC", "rock_largeE", "rock_tallA", "rock_tallC", "stone_largeB", "rock_smallA"],
		int(120 * detail), Vector2(2.5, 5.5), 1.8)


func _random_spot(on_hills: bool) -> Vector2:
	var limit := _track.arena_half + (Vector2(HILL_MARGIN, HILL_MARGIN) - Vector2(6, 6) if on_hills else Vector2(-3, -3))
	var p := Vector2(_rng.randf_range(-limit.x, limit.x), _rng.randf_range(-limit.y, limit.y))
	if on_hills:
		# Push points that fell inside the arena out to its nearest edge band.
		var inner := _track.arena_half + Vector2(5, 5)
		if absf(p.x) < inner.x and absf(p.y) < inner.y:
			if inner.x - absf(p.x) < inner.y - absf(p.y):
				p.x = signf(p.x) * _rng.randf_range(inner.x, limit.x)
			else:
				p.y = signf(p.y) * _rng.randf_range(inner.y, limit.y)
	return p


func _tree_fits(p: Vector2, on_hills: bool, height: float, spacing: float) -> bool:
	if _near_tree(p, spacing):
		return false
	if on_hills:
		return true
	if not _in_arena(p, 2.5):
		return false
	if _road_clearance(p) < Track.BARRIER_GAP + 3.0:
		return false
	if not _is_free(Rect2(p - Vector2(2, 2), Vector2(4, 4))):
		return false
	return not _blocks_view(p, height, 2.2)


func _near_tree(p: Vector2, spacing: float) -> bool:
	var home := Vector2i(floori(p.x / 4.0), floori(p.y / 4.0))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var key := home + Vector2i(dx, dz)
			if _tree_spots.has(key):
				for other: Vector2 in _tree_spots[key]:
					if other.distance_to(p) < spacing:
						return true
	return false


func _remember_tree(p: Vector2) -> void:
	var key := Vector2i(floori(p.x / 4.0), floori(p.y / 4.0))
	if not _tree_spots.has(key):
		_tree_spots[key] = []
	(_tree_spots[key] as Array).append(p)


func _scatter_small(models: Array, attempts: int, scale_range: Vector2, spacing: float) -> void:
	var lists: Dictionary = {}
	for attempt in attempts:
		var on_hills := attempt % 3 == 0
		var p := _random_spot(on_hills)
		if not on_hills:
			if not _in_arena(p, 2.0) or _road_clearance(p) < Track.BARRIER_GAP + 1.5:
				continue
			if not _is_free(Rect2(p - Vector2(1, 1), Vector2(2, 2))):
				continue
		if _near_tree(p, spacing):
			continue
		_remember_tree(p)
		var model: String = models[_rng.randi() % models.size()]
		if not lists.has(model):
			var fresh: Array[Transform3D] = []
			lists[model] = fresh
		var list: Array[Transform3D] = lists[model]
		var basis := Basis(Vector3.UP, _rng.randf_range(0, TAU)).scaled(Vector3.ONE * _rng.randf_range(scale_range.x, scale_range.y))
		list.append(Transform3D(basis, Vector3(p.x, _hill_height(p.x, p.y) - 0.05, p.y)))
	for model: String in lists:
		_bake(Models.baked_mesh(model), lists[model])


func _pick(kinds: Array) -> Dictionary:
	var total := 0.0
	for kind: Dictionary in kinds:
		total += float(kind.weight)
	var roll := _rng.randf() * total
	for kind: Dictionary in kinds:
		roll -= float(kind.weight)
		if roll <= 0.0:
			return kind
	return kinds[kinds.size() - 1]
