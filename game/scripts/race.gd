extends Node
## One run: countdown, lap counting through the track's gates, and the two ways a run ends
## (all laps done, or the time limit).

signal state_changed(state: int)
signal countdown_tick(seconds_left: int)
signal checkpoint_passed(lap: int, index: int, lap_ms: int)
signal lap_completed(lap: int, lap_ms: int)
signal finished(completed: bool, total_ms: int)

enum State { IDLE, COUNTDOWN, RACING, FINISHED }

const COUNTDOWN_SECONDS := 3

var state: State = State.IDLE
var laps_total := 3
var time_limit_ms := 90_000
## Lap gates in driving order; the last one is the finish line.
var gates: Array[Dictionary] = []

## The lap being driven, starting at 1.
var lap := 1
var lap_times_ms: Array[int] = []
var checkpoints_in_lap := 0

var _countdown_left := 0.0
var _last_tick := 0
var _run_started_ms := 0
var _lap_started_ms := 0
var _final_ms := 0


func start_countdown() -> void:
	lap = 1
	lap_times_ms = []
	checkpoints_in_lap = 0
	_final_ms = 0
	_countdown_left = float(COUNTDOWN_SECONDS)
	_last_tick = COUNTDOWN_SECONDS
	_set_state(State.COUNTDOWN)
	countdown_tick.emit(COUNTDOWN_SECONDS)


func reset() -> void:
	_set_state(State.IDLE)


## Milliseconds since GO; frozen once the run is over.
func elapsed_ms() -> int:
	match state:
		State.RACING:
			return Time.get_ticks_msec() - _run_started_ms
		State.FINISHED:
			return _final_ms
	return 0


func _process(delta: float) -> void:
	if state == State.COUNTDOWN:
		_countdown_left -= delta
		var tick := int(ceil(_countdown_left))
		if tick != _last_tick and tick > 0:
			_last_tick = tick
			countdown_tick.emit(tick)
		if _countdown_left <= 0.0:
			_run_started_ms = Time.get_ticks_msec()
			_lap_started_ms = _run_started_ms
			_set_state(State.RACING)
	elif state == State.RACING and elapsed_ms() >= time_limit_ms:
		_finish(false, time_limit_ms)


## Call every physics tick with where the car was and where it is now.
func track_movement(from: Vector3, to: Vector3) -> void:
	if state != State.RACING or gates.is_empty():
		return
	var gate: Dictionary = gates[checkpoints_in_lap]
	var center: Vector2 = gate.pos
	var direction: Vector2 = gate.dir
	var before := Vector2(from.x, from.z) - center
	var after := Vector2(to.x, to.z) - center
	# Crossed the gate's line going forwards, within its width.
	if before.dot(direction) >= 0.0 or after.dot(direction) < 0.0:
		return
	if absf(after.dot(Vector2(-direction.y, direction.x))) > float(gate.half):
		return

	var now := Time.get_ticks_msec()
	var lap_ms := now - _lap_started_ms
	if checkpoints_in_lap < gates.size() - 1:
		checkpoint_passed.emit(lap, checkpoints_in_lap, lap_ms)
		checkpoints_in_lap += 1
		return

	# The finish line, with every checkpoint of this lap behind us.
	lap_times_ms.append(lap_ms)
	lap_completed.emit(lap, lap_ms)
	checkpoints_in_lap = 0
	_lap_started_ms = now
	if lap >= laps_total:
		var total := 0
		for ms in lap_times_ms:
			total += ms
		_finish(true, total)
	else:
		lap += 1


func _finish(completed: bool, total_ms: int) -> void:
	_final_ms = total_ms
	_set_state(State.FINISHED)
	finished.emit(completed, total_ms)


func _set_state(next: State) -> void:
	state = next
	state_changed.emit(state)
