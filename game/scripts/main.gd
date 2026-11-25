extends Node3D
## Entry point. Reads how the page was opened, builds the world, and ties together the car,
## the run, the HUD and the session server.
##
##   /game/index.html?s=CODE              play in session CODE (identity comes from the join page)
##   /game/index.html?s=CODE&spectate=1   the big screen: every car, no controls
##   /game/index.html                     practice on the default track, nothing recorded
##   /game/index.html?track=ID            practice on another track (a file in game/tracks)
##   ...&station=1                        joined at the booth's laptop station: results offer
##                                        the next driver a go
##   ...&autopilot=1                     the car drives itself (demos, tuning lap times)
##   ...&debug=1                          shows the frame rate, for checking phones
##
## On a desktop the same options follow "--", and a joined player can be passed in for testing:
##   godot --path game -- s=CODE player=ID token=TOKEN autopilot

const Track := preload("res://scripts/track.gd")
const Car := preload("res://scripts/car.gd")
const Race := preload("res://scripts/race.gd")
const Net := preload("res://scripts/net.gd")
const Ghosts := preload("res://scripts/ghosts.gd")
const Hud := preload("res://scripts/hud.gd")
const Scenery := preload("res://scripts/scenery.gd")
const Audio := preload("res://scripts/audio.gd")

const DEFAULT_TRACK := "pipeline-park"
## Your own car is always Bitrise purple; other drivers' cars keep their colours.
const OWN_CAR_COLOR := Color("#9247c2")
## Shown on the start panel when there is no touch screen to drive with.
const KEY_HINT := "Drive with W A S D or the arrow keys. Enter starts."
const POSITION_INTERVAL := 0.1
const WELCOME_TIMEOUT := 5.0
## The driving camera never turns: it keeps this angle and follows the car, looking north.
const CAMERA_PITCH := 0.96
const CAMERA_DISTANCE := 38.0
const CAMERA_FOV := 34.0
## How far ahead of the car the camera looks, in seconds of travel.
const CAMERA_LEAD := 0.45
const INTRO_SECONDS := 4.2
## In the last seconds of a run a tick sounds every second.
const TICK_FROM_MS := 10_000
const COL_BOOST := Color("#11bba9")
const COL_BUG := Color("#f7596c")
const COL_GOLD := Color("#f9cc15")

var session_code := ""
var spectating := false
var autopilot := false
## Opened from the booth's laptop station (see the site's /station page).
var station := false
var debug := false
## Who we are in the session: { playerId, token, name, color }. Empty when practising.
var identity: Dictionary = {}

var track: Track
var car: Car
var race: Race
var net: Net
var ghosts: Ghosts
var hud: Hud
var scenery: Scenery
var audio: Audio
var camera: Camera3D
var sun: DirectionalLight3D
## Phones get fewer trees, smaller shadows and no glow.
var low_end := false

var _laps_total := 3
var _time_limit_ms := 90_000
var _session_name := ""
var _session_open := true
var _leaderboard: Array = []
var _welcomed := false
var _welcome_wait := 0.0
var _stopped_reason := ""
var _position_timer := 0.0
var _previous_position := Vector3.ZERO
var _camera_target := Vector3.ZERO
var _key_steer := 0.0
var _path_hint := -1
var _autopilot_restart := 0.0
var _result_delay := -1.0
var _last_run: Dictionary = {}
## Physics ticks since GO and at the last lap line; lets headless autopilot runs report lap
## times in simulated seconds (see scripts/measure-laps.sh).
var _sim_ticks := 0
var _sim_lap_start := 0
## The fly-over before the first countdown: < 0 when not playing.
var _intro_time := -1.0
var _intro_done := false
## True while the screen fades out to go back to the grid.
var _starting := false
## Camera shake left from a bump or a bug, 0 to 1; it dies away by itself.
var _shake := 0.0
## Seconds until the start lights go back to their idle sweep.
var _lights_idle_in := -1.0
var _last_tick_second := -1
## The big screen remembers who leads, to make a fuss when that changes.
var _leader := ""
## When a crowd last cheered out loud, so neighbouring stands do not all roar at once.
var _last_cheer_ms := -100_000


func _ready() -> void:
	var query := _read_query()
	session_code = _clean_code(str(query.get("s", "")))
	spectating = query.has("spectate")
	autopilot = query.has("autopilot")
	station = query.has("station")
	debug = query.has("debug")

	_setup_rendering()
	_setup_scene()

	hud = Hud.new()
	hud.spectating = spectating
	add_child(hud)
	hud.primary_pressed.connect(_on_primary_pressed)
	hud.secondary_pressed.connect(_next_driver)
	hud.skip_requested.connect(_finish_intro)

	# Sound starts on for players and off on the big screen, then remembers what was chosen.
	audio = Audio.new()
	add_child(audio)
	audio.load_preference("spectator" if spectating else "player", not spectating)
	hud.set_sound(audio.enabled)
	hud.sound_toggled.connect(func(on: bool) -> void:
		audio.set_enabled(on)
		audio.play("click"))
	hud.ui_clicked.connect(func() -> void: audio.play("click"))

	ghosts = Ghosts.new()
	ghosts.solid = spectating
	ghosts.effects = spectating
	ghosts.max_visible = 64 if spectating else 12
	ghosts.label_scale = 3.2 if spectating else 1.0
	add_child(ghosts)

	if session_code.is_empty():
		_build_world(_clean_track_id(str(query.get("track", DEFAULT_TRACK))))
		_show_start_panel()
		return

	if not spectating:
		identity = _read_identity(query)
		if identity.is_empty() and OS.has_feature("web"):
			# Opened the game directly without joining first: send them to the join page.
			JavaScriptBridge.eval("window.location.replace('/join/%s')" % session_code, true)
			return
	ghosts.own_id = str(identity.get("playerId", ""))

	net = Net.new()
	add_child(net)
	net.message_received.connect(_on_message)
	net.opened.connect(func() -> void: hud.set_status(""))
	net.closed.connect(_on_connection_lost)
	net.connect_to(_socket_url())
	hud.show_panel("Connecting…", "Finding session %s" % session_code, "")


# --- setup ------------------------------------------------------------------------------------

func _read_query() -> Dictionary:
	var pairs := PackedStringArray()
	if OS.has_feature("web"):
		pairs = str(JavaScriptBridge.eval("window.location.search", true)).trim_prefix("?").split("&", false)
	else:
		# Desktop runs take the same parameters after "--":  godot --path game -- s=ABCDE autopilot
		pairs = OS.get_cmdline_user_args()
	var result := {}
	for pair in pairs:
		var parts := pair.split("=", true, 1)
		result[parts[0].uri_decode()] = parts[1].uri_decode() if parts.size() > 1 else ""
	return result


## A track id becomes part of a file path, so allow only lower-case letters, digits and dashes.
static func _clean_track_id(raw: String) -> String:
	var cleaned := ""
	for character in raw:
		if (character >= "a" and character <= "z") or (character >= "0" and character <= "9") or character == "-":
			cleaned += character
	return cleaned if cleaned == raw and not cleaned.is_empty() else DEFAULT_TRACK


## Session codes end up inside a JavaScript snippet and a URL, so allow only letters and digits.
static func _clean_code(raw: String) -> String:
	var cleaned := ""
	for character in raw.to_upper():
		if (character >= "A" and character <= "Z") or (character >= "0" and character <= "9"):
			cleaned += character
	return cleaned.left(12)


func _read_identity(query: Dictionary) -> Dictionary:
	if not OS.has_feature("web"):
		# Desktop test runs pass an identity on the command line:  -- s=CODE player=ID token=TOKEN
		if query.has("player") and query.has("token"):
			return {"playerId": str(query.player), "token": str(query.token), "name": str(query.get("name", "Tester")),
				"color": str(query.get("color", "#11bba9"))}
		return {}
	var raw: Variant = JavaScriptBridge.eval(
		"(function(){try{return window.localStorage.getItem('bitrise-grand-prix:player:%s')}catch(e){return null}})()" % session_code, true)
	if not raw is String:
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Dictionary and parsed.has("token") and parsed.has("playerId"):
		return parsed
	return {}


func _socket_url() -> String:
	var base := "ws://localhost:8787"
	if OS.has_feature("web"):
		base = str(JavaScriptBridge.eval(
			"(window.location.protocol === 'https:' ? 'wss://' : 'ws://') + window.location.host", true))
	var url := "%s/ws?session=%s" % [base, session_code]
	if spectating:
		return url + "&role=spectator"
	return url + "&role=player&token=%s" % str(identity.get("token", "")).uri_encode()


func _setup_rendering() -> void:
	if not OS.has_feature("web"):
		return
	# Phones report 2x-3x pixel ratios; drawing 3D at full density costs frames for no visible
	# gain in a fast top-down game. The HUD stays sharp either way.
	var ratio := float(JavaScriptBridge.eval("window.devicePixelRatio || 1", true))
	var phone := Hud.has_touch_screen()
	low_end = phone and not spectating
	# Only phones and tablets: a laptop's high-density screen kept at full resolution and with
	# anti-aliasing, or the car looks soft and its edges shimmer when it moves.
	if phone and ratio > 1.5:
		get_viewport().scaling_3d_scale = clampf(1.5 / ratio, 0.5, 1.0)
		get_viewport().msaa_3d = Viewport.MSAA_DISABLED


func _setup_scene() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#3e7448")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#c7cff2")
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.05
	if not low_end:
		# Lets the pickups' glowing edges bloom on the big screen.
		environment.glow_enabled = true
		environment.glow_intensity = 0.7
		environment.glow_hdr_threshold = 1.0
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)

	# Late-afternoon sun from the top left, so shadows fall towards the bottom right of the screen.
	sun = DirectionalLight3D.new()
	sun.basis = Basis.looking_at(Vector3(0.55, -0.78, 0.32).normalized(), Vector3.UP)
	sun.light_color = Color("#fff1dc")
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.shadow_blur = 1.2
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 320.0 if spectating else 95.0
	add_child(sun)
	RenderingServer.directional_shadow_atlas_set_size(2048 if low_end else 4096, true)

	camera = Camera3D.new()
	camera.fov = CAMERA_FOV
	camera.near = 1.0
	camera.far = 800.0
	add_child(camera)
	camera.make_current()
	camera.position = Vector3(0, 120, 70)
	camera.look_at(Vector3(0, 0, 5))


func _build_world(track_id: String) -> void:
	if track:
		return
	track = Track.new()
	add_child(track)
	if not track.build(track_id):
		track.build(DEFAULT_TRACK)
	scenery = Scenery.new()
	scenery.detail = 0.6 if low_end else 1.0
	add_child(scenery)
	scenery.build(track)
	scenery.cheered.connect(_on_cheer)
	ghosts.track = track
	hud.reveal()

	if spectating:
		return

	car = Car.new()
	car.track = track
	car.color = OWN_CAR_COLOR
	add_child(car)
	car.reset_to(track.spawn_position, track.spawn_heading)
	car.effect_applied.connect(_on_effect)
	car.bumped.connect(_on_bump)
	car.landed.connect(_on_landed)
	car.effects_enabled = true
	_camera_target = track.spawn_position
	_previous_position = track.spawn_position
	hud.set_track_title(str(track.data.get("name", "")), _laps_total)
	# Each track sets its own time limit. In a session the server sends the same number.
	_time_limit_ms = int(track.data.get("timeLimitMs", _time_limit_ms))

	race = Race.new()
	race.gates = track.gates
	race.laps_total = _laps_total
	race.time_limit_ms = _time_limit_ms
	add_child(race)
	race.countdown_tick.connect(_on_countdown)
	race.state_changed.connect(_on_race_state)
	# The server times checkpoints itself from positions; report one the moment a gate is crossed.
	race.checkpoint_passed.connect(func(_lap: int, _index: int, _ms: int) -> void:
		_send_position()
		audio.play("checkpoint"))
	race.lap_completed.connect(_on_lap)
	race.finished.connect(_on_finished)


# --- server messages --------------------------------------------------------------------------

func _on_message(message: Dictionary) -> void:
	match str(message.get("t", "")):
		"welcome":
			_welcomed = true
			_laps_total = int(message.get("laps", 3))
			var session: Dictionary = message.get("session", {})
			_apply_session(session)
			_build_world(str(session.get("trackId", DEFAULT_TRACK)))
			# The server referees the run, so its time limit wins over the game's copy of the track.
			var limit := int(message.get("timeLimitMs", 0))
			if limit > 0:
				_time_limit_ms = limit
				race.time_limit_ms = limit
			if race and race.state == Race.State.IDLE:
				_show_start_panel()
			elif spectating:
				hud.hide_panel()
		"session":
			_apply_session(message.get("session", {}))
		"snapshot":
			ghosts.apply_snapshot(message.get("cars", []))
		"standing":
			if race and (race.state == Race.State.RACING or race.state == Race.State.COUNTDOWN):
				hud.set_standing(message)
		"run_result":
			_last_run["server"] = message
			if hud.is_panel_visible() and race and race.state == Race.State.FINISHED:
				_show_result_panel()
		"closed":
			_session_open = false
			if spectating:
				hud.show_led("CLOSED", Hud.COL_LED, 3.5)
			elif race and race.state != Race.State.RACING and race.state != Race.State.COUNTDOWN:
				_show_start_panel()
		"removed":
			_stopped_reason = "The host removed you from this session."
			net.disconnect_from_server()
			_show_start_panel()
		"error":
			hud.show_toast(str(message.get("message", "")), Color("#ff8091"), 2.0)


func _apply_session(session: Dictionary) -> void:
	if session.is_empty():
		return
	_session_name = str(session.get("name", ""))
	_session_open = str(session.get("status", "open")) == "open"
	_leaderboard = session.get("leaderboard", [])
	ghosts.set_players(session.get("players", []))
	if spectating:
		_check_leader()


## On the big screen: a fanfare and a toast when someone takes the lead with a finished run.
func _check_leader() -> void:
	var top: Dictionary = _leaderboard[0] if not _leaderboard.is_empty() else {}
	if not top.get("finished", false):
		return
	var leader := "%s/%d" % [str(top.get("playerId", "")), int(top.get("totalMs", 0))]
	if leader == _leader:
		return
	var first := _leader.is_empty()
	_leader = leader
	if first:
		return
	hud.show_toast("NEW LEADER  %s  %s" % [str(top.get("name", "")), Hud.format_time(int(top.get("totalMs", 0)))], COL_GOLD, 2.6)
	audio.play("finish")
	audio.play("cheer", 3.0)


func _on_connection_lost() -> void:
	if not spectating:
		hud.set_status("RECONNECTING…")
	ghosts.clear()


## Where the car is: other players draw it, and the server's referee works out checkpoints,
## laps and times from these on its own clock. `ct` is the time since GO on this device.
func _send_position() -> void:
	if not net or not car or not race:
		return
	var at := car.global_position
	_send({
		"t": "pos",
		"p": [snappedf(at.x, 0.01), snappedf(at.y, 0.01), snappedf(at.z, 0.01), snappedf(car.heading, 0.01)],
		"ct": race.elapsed_ms(),
		"fx": car.effect,
	})


func _send(message: Dictionary) -> void:
	if net:
		net.send(message)


# --- the run ----------------------------------------------------------------------------------

func _on_primary_pressed() -> void:
	if not race or not _stopped_reason.is_empty():
		return
	if net and not _session_open:
		return
	if race.state == Race.State.IDLE or race.state == Race.State.FINISHED:
		_start_run()


func _start_run() -> void:
	if _starting:
		return
	_starting = true
	_last_run = {}
	_result_delay = -1.0
	hud.hide_panel()
	# Back to the grid behind a quick fade, so the camera does not jump in plain sight.
	hud.transition(_begin_run)


func _begin_run() -> void:
	_starting = false
	_path_hint = -1
	_last_tick_second = -1
	_lights_idle_in = -1.0
	track.set_start_lights("red", 0)
	car.controls_locked = true
	car.reset_to(track.spawn_position, track.spawn_heading)
	_previous_position = track.spawn_position
	_camera_target = track.spawn_position
	_sim_ticks = 0
	_sim_lap_start = 0
	hud.reset_run(net != null)
	if not _intro_done and not autopilot:
		_start_intro()
	else:
		race.start_countdown()


## A short fly-over from the whole track down to the grid, with the track name. Tap to skip.
func _start_intro() -> void:
	_intro_time = 0.0
	hud.show_intro(true)


func _finish_intro() -> void:
	if _intro_time < 0.0:
		return
	_intro_time = -1.0
	_intro_done = true
	hud.show_intro(false)
	race.start_countdown()


func _update_intro(delta: float) -> void:
	_intro_time += delta
	var t := clampf(_intro_time / INTRO_SECONDS, 0.0, 1.0)
	var eased := t * t * (3.0 - 2.0 * t)
	# From high above the whole track, sweeping in over the start straight to the grid.
	var behind := track.point_at(float((track.data.get("centerline", []) as Array).size()) - 1.6)
	var behind_3d := Vector3(behind.x, 0, behind.y)
	var high := Vector3(0, 150, 95)
	var mid := Vector3(behind.x, 26, behind.y + 30)
	var end_target := _camera_goal()
	var end_eye := end_target + Vector3(0, sin(CAMERA_PITCH), cos(CAMERA_PITCH)) * CAMERA_DISTANCE
	# A quadratic Bezier for both the eye and the point it looks at.
	var eye := high.lerp(mid, eased).lerp(mid.lerp(end_eye, eased), eased)
	var look := Vector3.ZERO.lerp(behind_3d, eased).lerp(behind_3d.lerp(end_target, eased), eased)
	camera.global_position = eye
	camera.look_at(look, Vector3.UP)
	camera.fov = lerpf(46.0, CAMERA_FOV, eased)
	_camera_target = end_target
	if _intro_time >= INTRO_SECONDS:
		_finish_intro()


## 3, 2, 1: a beep each, and the start lights come on two, four, then all five.
func _on_countdown(seconds: int) -> void:
	hud.show_countdown(str(seconds))
	audio.play("beep")
	track.set_start_lights("red", [5, 4, 2][clampi(seconds - 1, 0, 2)])


func _on_race_state(state: int) -> void:
	match state:
		Race.State.RACING:
			car.controls_locked = false
			hud.sticks_enabled = true
			hud.show_countdown("GO")
			hud.flash(COL_BOOST, 0.22)
			audio.play("go")
			track.set_start_lights("green")
			_lights_idle_in = 3.0
			_send({"t": "run_start"})
		Race.State.COUNTDOWN:
			hud.sticks_enabled = true
		_:
			hud.sticks_enabled = false


func _on_lap(lap: int, _lap_ms: int) -> void:
	_send_position()
	if autopilot and not OS.has_feature("web"):
		var rate := float(Engine.physics_ticks_per_second)
		print("lap %d: %.2f s simulated" % [lap, (_sim_ticks - _sim_lap_start) / rate])
		_sim_lap_start = _sim_ticks
	# No pop-up: the corner readout already counts laps, and a chime marks the new one.
	if lap == _laps_total - 1:
		audio.play("final_lap")
	elif lap < _laps_total:
		audio.play("lap")


func _on_finished(completed: bool, total_ms: int) -> void:
	car.controls_locked = true
	_last_run = {"completed": completed, "total_ms": total_ms}
	# Only says how the run ended; the server already has the laps and times.
	_send({"t": "run_finish", "finished": completed})
	if completed:
		hud.show_led("FINISH", Hud.COL_ACCENT, 0.9)
	else:
		hud.show_led("TIME'S UP", Hud.COL_WARN, 0.9)
	if completed:
		audio.play("finish")
		audio.play("cheer", 2.0)
		track.set_start_lights("finish")
	else:
		audio.play("buzzer")
		track.set_start_lights("red", 5)
	_lights_idle_in = 4.0
	# The results wait for the LED board to clear (about 1.9 s, see Hud.show_led).
	_result_delay = 1.9
	_autopilot_restart = 5.0


## No pop-up: the screen edges glow in the box's colour, and the sound says which it was.
func _on_effect(kind: String) -> void:
	if kind == "boost":
		hud.pulse_edges(COL_BOOST, 0.5)
		audio.play("boost")
	else:
		hud.pulse_edges(COL_BUG, 0.6)
		audio.play("bug")
		_shake = maxf(_shake, 0.55)


## Bounced off the Armco or a wall: louder and shakier the harder it was.
func _on_bump(strength: float) -> void:
	var hardness := clampf(strength / 16.0, 0.25, 1.0)
	audio.play("bump", linear_to_db(hardness), randf_range(0.9, 1.1))
	_shake = maxf(_shake, hardness * 0.6)


func _on_landed(air_time: float) -> void:
	audio.play("land", linear_to_db(clampf(air_time, 0.4, 1.0)))
	_shake = maxf(_shake, 0.3)


## A crowd cheering a car going past, louder the closer it came.
func _on_cheer(strength: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_cheer_ms < 2500:
		return
	_last_cheer_ms = now
	audio.play("cheer", linear_to_db(lerpf(0.35, 1.0, strength)), randf_range(0.92, 1.08))


func _show_start_panel() -> void:
	if not _stopped_reason.is_empty():
		hud.show_panel("Game over", _stopped_reason, "")
		return
	var laps := "%d laps, %d seconds on the clock." % [_laps_total, _time_limit_ms / 1000]
	var keys := "" if hud.touch_controls else KEY_HINT
	if not net:
		hud.show_panel("Practice run", laps, "START", ("Not connected to a session, so nothing is recorded. " + keys).strip_edges())
	elif not _session_open:
		hud.show_results("Session closed", "", "", _board_rows(), _own_board_row(), _session_name, -1, _next_driver_text())
	else:
		hud.show_panel(str(identity.get("name", "Ready?")), "%s\n%s" % [_session_name, laps], "START", keys)


func _show_result_panel() -> void:
	var completed: bool = _last_run.get("completed", false)
	var title := Hud.format_time(int(_last_run.get("total_ms", 0))) if completed else "%d/%d laps" % [race.lap_times_ms.size(), _laps_total]
	var subtitle := ""
	if not net:
		subtitle = "Practice run, not recorded."
	else:
		var server: Dictionary = _last_run.get("server", {})
		if server.is_empty():
			subtitle = "Sending your result…"
		elif server.get("accepted", false):
			# The server's time is the official one (it may differ by a few hundredths).
			var result: Dictionary = server.get("result", {})
			if completed and result.has("totalMs"):
				title = Hud.format_time(int(result.get("totalMs", 0)))
			subtitle = "You are #%d in %s" % [int(server.get("rank", 0)), _session_name]
		elif str(server.get("reason", "")) == "no progress":
			subtitle = "That one did not count. Try again!"
		else:
			subtitle = "This run was not recorded (%s)." % str(server.get("reason", "unknown"))
	var can_retry := not net or _session_open
	var count_to: int = int(_last_run.get("total_ms", 0)) if completed else -1
	hud.show_results(title, subtitle, "RACE AGAIN" if can_retry else "", _board_rows(), _own_board_row(), _session_name, count_to,
		_next_driver_text())


## At the laptop station, the results also offer the next driver a go.
func _next_driver_text() -> String:
	return "NEXT DRIVER" if station and net else ""


## Back to the laptop station's page, where the next driver types a name.
func _next_driver() -> void:
	if station and OS.has_feature("web"):
		# The session code is letters and digits only (see _clean_code).
		JavaScriptBridge.eval("window.location.assign('/station/%s')" % session_code)


func _board_rows() -> Array:
	var rows: Array = []
	for entry: Dictionary in _leaderboard.slice(0, 5):
		rows.append(_board_row(entry))
	# Outside the top five: still show where you stand.
	var own := str(identity.get("playerId", ""))
	for i in range(5, _leaderboard.size()):
		if str(_leaderboard[i].get("playerId", "")) == own:
			rows.append(_board_row(_leaderboard[i]))
	return rows


## [position, name, total time, colour]
func _board_row(entry: Dictionary) -> Array:
	var time := Hud.format_time(int(entry.get("totalMs", 0))) if entry.get("finished", false) else "%d/%d laps" % [int(entry.get("lapsCompleted", 0)), _laps_total]
	return [str(int(entry.get("rank", 0))), str(entry.get("name", "")), time, str(entry.get("color", "#9247c2"))]


func _own_board_row() -> int:
	var own := str(identity.get("playerId", ""))
	var rows := _leaderboard.slice(0, 5)
	for i in rows.size():
		if str(rows[i].get("playerId", "")) == own:
			return i
	return 5 if _leaderboard.size() > 5 else -1


# --- every frame ------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if debug:
		hud.set_status("%d FPS  ·  %d draw calls" % [Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)])
	if net and not _welcomed and not track:
		_welcome_wait += delta
		if _welcome_wait > WELCOME_TIMEOUT:
			# The server is not answering. Let people drive anyway instead of staring at a spinner.
			_welcomed = true
			_build_world(DEFAULT_TRACK)
			if spectating:
				hud.show_panel("No connection", "Could not reach session %s. Still trying…" % session_code, "")
			else:
				net.disconnect_from_server()
				net.queue_free()
				net = null
				_show_start_panel()

	if spectating:
		_update_spectator_camera()
		ghosts.focus = Vector3.ZERO
		if scenery:
			scenery.update_focus(ghosts.positions(), delta)
		return
	if not car or not race:
		return

	_read_controls(delta)
	if _intro_time >= 0.0:
		_update_intro(delta)
	else:
		_update_chase_camera(delta)
	ghosts.focus = car.global_position
	var focus: Array[Vector3] = [car.global_position]
	scenery.update_focus(focus, delta)

	var time_left: int = _time_limit_ms - race.elapsed_ms() if race.state == Race.State.RACING else -1
	hud.set_race_readout(race.lap, _laps_total, race.elapsed_ms(), time_left)
	if time_left >= 0 and time_left <= TICK_FROM_MS:
		var second := int(ceil(time_left / 1000.0))
		if second != _last_tick_second:
			_last_tick_second = second
			audio.play("tick")

	var running := (race.state == Race.State.COUNTDOWN or race.state == Race.State.RACING) and _intro_time < 0.0
	var throttle := 0.0 if car.controls_locked else car.throttle_input
	audio.update_car(car.forward_speed, throttle, car.effect == 1, car.skid_level(), running, delta)

	if _lights_idle_in > 0.0:
		_lights_idle_in -= delta
		if _lights_idle_in <= 0.0 and race.state != Race.State.COUNTDOWN:
			track.set_start_lights("idle")

	if race.state == Race.State.RACING:
		_position_timer += delta
		if _position_timer >= POSITION_INTERVAL:
			_position_timer = 0.0
			_send_position()

	if _result_delay >= 0.0:
		_result_delay -= delta
		if _result_delay < 0.0:
			_show_result_panel()

	if autopilot and (race.state == Race.State.IDLE or race.state == Race.State.FINISHED):
		_autopilot_restart -= delta
		if _autopilot_restart <= 0.0 and (not net or (_welcomed and _session_open)):
			_start_run()


func _physics_process(_delta: float) -> void:
	if not car or not race:
		return
	var now := car.global_position
	if race.state == Race.State.RACING:
		_sim_ticks += 1
	race.track_movement(_previous_position, now)
	_previous_position = now


func _read_controls(delta: float) -> void:
	var steer: float = hud.steer
	var throttle: float = hud.throttle

	if autopilot:
		var drive := _autopilot_input()
		steer = drive.x
		throttle = drive.y
	else:
		# Keyboard, for trying the game on a laptop. Eased so a key press is not full lock at once.
		var key_steer := Input.get_axis("ui_left", "ui_right")
		if Input.is_physical_key_pressed(KEY_A):
			key_steer -= 1.0
		if Input.is_physical_key_pressed(KEY_D):
			key_steer += 1.0
		_key_steer = move_toward(_key_steer, clampf(key_steer, -1.0, 1.0), delta * 7.0)
		var key_throttle := Input.get_axis("ui_down", "ui_up")
		if Input.is_physical_key_pressed(KEY_W):
			key_throttle += 1.0
		if Input.is_physical_key_pressed(KEY_S):
			key_throttle -= 1.0
		if absf(_key_steer) > absf(steer):
			steer = _key_steer
		if absf(key_throttle) > absf(throttle):
			throttle = clampf(key_throttle, -1.0, 1.0)
		if race.state == Race.State.IDLE or race.state == Race.State.FINISHED:
			if Input.is_action_just_pressed("ui_accept") and hud.is_panel_visible():
				_on_primary_pressed()
			elif station and Input.is_action_just_pressed("ui_cancel") and hud.is_panel_visible():
				_next_driver()

	car.steer_input = steer
	car.throttle_input = throttle
	hud.mirror_input(steer, throttle)


## Follows the centreline: aim at a point a little ahead and lift off when the turn is sharp.
func _autopilot_input() -> Vector2:
	_path_hint = track.nearest_path_index(car.global_position, _path_hint)
	var count: int = track.path.size()
	var target: Vector2 = track.path[(_path_hint + 6) % count]
	var to_target := Vector2(target.x - car.global_position.x, target.y - car.global_position.z)
	var error := wrapf(to_target.angle() - car.heading, -PI, PI)
	return Vector2(clampf(error * 2.4, -1.0, 1.0), 1.0 if absf(error) < 0.55 else 0.45)


## Where the driving camera wants to look: the car, plus a little of the road ahead of it.
func _camera_goal() -> Vector3:
	var velocity := car.linear_velocity
	var lead := Vector3(velocity.x, 0, velocity.z) * CAMERA_LEAD
	# Where the car is drawn, which glides between physics steps (see Car.render_position).
	return Vector3(car.render_position.x, 0, car.render_position.z) + lead.limit_length(11.0)


func _update_chase_camera(delta: float) -> void:
	_camera_target = _camera_target.lerp(_camera_goal(), 1.0 - exp(-3.5 * delta))
	var eye := Vector3(0, sin(CAMERA_PITCH), cos(CAMERA_PITCH)) * CAMERA_DISTANCE
	camera.global_position = _camera_target + eye
	camera.look_at(_camera_target, Vector3.UP)
	_shake = maxf(0.0, _shake - delta * 1.8)
	var jolt := _shake * _shake * 0.8
	camera.h_offset = randf_range(-jolt, jolt)
	camera.v_offset = randf_range(-jolt, jolt)
	# A little extra field of view sells the boost.
	var target_fov := CAMERA_FOV + clampf((car.forward_speed - Car.MAX_SPEED) * 0.5, 0.0, 6.0)
	camera.fov = lerpf(camera.fov, target_fov, 1.0 - exp(-6.0 * delta))


## Frames the whole arena whatever the shape of the screen.
func _update_spectator_camera() -> void:
	if not track:
		return
	var size := get_viewport().get_visible_rect().size
	var aspect := size.x / maxf(1.0, size.y)
	var half: Vector2 = track.arena_half
	var eye := Vector3(0, 1.0, 0.62).normalized()
	var target := Vector3(0, 0, half.y * 0.06)
	var vertical_fov := deg_to_rad(42.0)
	# Distance needed to fit the depth, and the distance needed to fit the width.
	var for_depth := (half.y * 1.08) / tan(vertical_fov * 0.5) * 0.9
	var for_width := (half.x * 1.06) / (tan(vertical_fov * 0.5) * aspect)
	camera.fov = rad_to_deg(vertical_fov)
	camera.global_position = target + eye * maxf(for_depth, for_width)
	camera.look_at(target, Vector3.UP)
