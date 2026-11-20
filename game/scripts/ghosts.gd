extends Node3D
## Other players' cars. The server relays everyone's position about ten times a second;
## this draws each one slightly in the past and interpolates between samples, so ghosts
## move smoothly even on patchy conference Wi-Fi. Ghosts have no physics: you cannot hit them.

const CarVisual := preload("res://scripts/car_visual.gd")
const CarFx := preload("res://scripts/car_fx.gd")

## How far behind real time ghosts are drawn; must exceed the gap between two snapshots.
const DELAY_SECONDS := 0.18
const FORGET_AFTER_SECONDS := 1.5

## The local player's id, never drawn as a ghost. Empty for spectators.
var own_id := ""
## Semi-transparent for players (so your own car stands out), solid for the big screen.
var solid := false
## Phones only draw the closest few; the big screen draws everyone.
var max_visible := 12
var label_scale := 1.0
## Where "closest" is measured from.
var focus := Vector3.ZERO
## Smoke, dust and tyre marks behind every ghost. Only the big screen can afford it.
var effects := false
## Asked whether a ghost is on the road, for its effects.
var track: Node3D

var _players: Dictionary = {}   # id -> { name, color }
var _ghosts: Dictionary = {}    # id -> { node, samples: Array, seen: float }
var _clock := 0.0


func set_players(players: Array) -> void:
	_players.clear()
	for player: Dictionary in players:
		_players[str(player.get("id", ""))] = player
	# A car can show up in a snapshot before the roster that names it; fix those up now.
	for id: String in _ghosts.keys():
		var ghost: Dictionary = _ghosts[id]
		if not ghost.named and _players.has(id):
			ghost.node.queue_free()
			ghost.node = _spawn(id)
			ghost.named = true
			if ghost.has("fx"):
				ghost.fx.queue_free()
				ghost.erase("fx")


func count() -> int:
	return _ghosts.size()


func apply_snapshot(cars: Array) -> void:
	for car: Dictionary in cars:
		var id := str(car.get("id", ""))
		var pose: Array = car.get("p", [])
		if id.is_empty() or id == own_id or pose.size() < 4:
			continue
		if not _ghosts.has(id):
			_ghosts[id] = {"node": _spawn(id), "samples": [], "seen": _clock, "named": _players.has(id)}
		var ghost: Dictionary = _ghosts[id]
		ghost.seen = _clock
		var samples: Array = ghost.samples
		samples.append({
			"t": _clock,
			"position": Vector3(float(pose[0]), float(pose[1]), float(pose[2])),
			"heading": float(pose[3]),
			"fx": int(car.get("fx", 0)),
		})
		while samples.size() > 12:
			samples.pop_front()


func clear() -> void:
	for ghost: Dictionary in _ghosts.values():
		_free(ghost)
	_ghosts.clear()


## Where every ghost is now; crowds cheer for the ones close by.
func positions() -> Array[Vector3]:
	var result: Array[Vector3] = []
	for ghost: Dictionary in _ghosts.values():
		result.append((ghost.node as Node3D).position)
	return result


func _free(ghost: Dictionary) -> void:
	ghost.node.queue_free()
	if ghost.has("fx"):
		ghost.fx.queue_free()


func _process(delta: float) -> void:
	_clock += delta
	var render_time := _clock - DELAY_SECONDS
	var by_distance: Array = []

	for id: String in _ghosts.keys():
		var ghost: Dictionary = _ghosts[id]
		if _clock - float(ghost.seen) > FORGET_AFTER_SECONDS:
			_free(ghost)
			_ghosts.erase(id)
			continue
		var samples: Array = ghost.samples
		if samples.is_empty():
			continue

		# Find the two samples around render_time; fall back to the nearest end.
		var a: Dictionary = samples[0]
		var b: Dictionary = samples[samples.size() - 1]
		for i in samples.size() - 1:
			if float(samples[i + 1].t) >= render_time:
				a = samples[i]
				b = samples[i + 1]
				break
		var span := float(b.t) - float(a.t)
		var t := 1.0 if span <= 0.0001 else clampf((render_time - float(a.t)) / span, 0.0, 1.0)
		var node: Node3D = ghost.node
		var from: Vector3 = a.position
		var to: Vector3 = b.position
		var at := from.lerp(to, t)
		var heading := lerp_angle(float(a.heading), float(b.heading), t)
		# Positions are of the sphere's centre; the visual's origin sits on the ground.
		var previous := node.position
		node.position = Vector3(at.x, maxf(0.0, at.y - 0.6), at.z)
		node.rotation.y = -heading
		node.call("set_effect", int(b.fx))
		_animate(ghost, node, previous, heading, int(b.fx), delta)
		by_distance.append([node.position.distance_squared_to(focus), node])

	if by_distance.size() > max_visible:
		by_distance.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	for i in by_distance.size():
		by_distance[i][1].visible = i < max_visible


## Wheels, steering and (on the big screen) effects, worked out from how the ghost moved.
func _animate(ghost: Dictionary, node: Node3D, previous: Vector3, heading: float, fx: int, delta: float) -> void:
	if delta <= 0.0:
		return
	var forward := Vector3(cos(heading), 0, sin(heading))
	var moved := node.position - previous
	var speed := Vector3(moved.x, 0, moved.z).dot(forward) / delta
	var last_heading := float(ghost.get("heading", heading))
	var turn := wrapf(heading - last_heading, -PI, PI) / delta
	ghost.heading = heading
	# Smooth both: snapshots arrive ten times a second and frames are not evenly spaced.
	var smooth_speed := lerpf(float(ghost.get("speed", 0.0)), speed, 1.0 - exp(-10.0 * delta))
	var smooth_turn := lerpf(float(ghost.get("turn", 0.0)), turn, 1.0 - exp(-8.0 * delta))
	ghost.speed = smooth_speed
	ghost.turn = smooth_turn
	node.call("set_wheel_speed", smooth_speed)
	node.call("set_steer", clampf(smooth_turn / 2.7, -1.0, 1.0))
	if not effects or not node.visible:
		return
	if not ghost.has("fx"):
		var car_fx := CarFx.new()
		add_child(car_fx)
		ghost.fx = car_fx
		ghost.road_check = 0.0
		ghost.on_road = true
	ghost.road_check = float(ghost.road_check) - delta
	if float(ghost.road_check) <= 0.0 and track:
		ghost.road_check = 0.15
		ghost.on_road = track.call("is_on_road", node.position)
	var grounded := node.position.y < 0.25
	(ghost.fx as CarFx).feed(node.position, heading, smooth_speed, smooth_turn, 0.0,
		bool(ghost.on_road), grounded, fx, delta)


func _spawn(id: String) -> Node3D:
	var player: Dictionary = _players.get(id, {})
	var node := CarVisual.new()
	node.color = Color(str(player.get("color", "#11bba9")))
	node.display_name = str(player.get("name", "Racer"))
	node.ghost = not solid
	add_child(node)
	node.call("set_label_scale", label_scale)
	return node
