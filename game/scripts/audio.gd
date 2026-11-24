extends Node
## Sound effects, all made from scratch when the game loads, so there are no audio files to
## ship or license: the RC motor's whine, tyre squeal, boost and bug hits, checkpoint and lap
## chimes, countdown beeps, the finish fanfare, bumps, landings, crowd cheers and button clicks.
## One sound is generated per frame, so loading never stalls on them.
##
## Browsers only start audio after a tap or a key press; Godot resumes it on the first one.
##
## The motor and the tyre squeal are not looped by Godot: in the browser build (4.7) a looped
## sound restarts at its original pitch and with a small gap each time round, so a motor would
## stutter and stop following the car's speed. Instead each is a two-second sound with soft
## ends, started again here just before the previous one finishes, overlapping it a little.

const RATE := 22050
## Lower-pitched and noisy sounds are made at a lower rate: half the work, no audible loss.
const LOW_RATE := 16000
const STORAGE_KEY := "bitrise-grand-prix:sound:%s"
## How long the motor and squeal sounds are, and how much one overlaps the next, in seconds.
const LOOP_SECONDS := 2.0
const LOOP_OVERLAP := 0.08

## Each sound's usual level in dB, before any per-call adjustment.
const LEVELS := {
	"click": -12.0,
	"beep": -9.0,
	"go": -7.0,
	"tick": -15.0,
	"checkpoint": -13.0,
	"boost": -6.0,
	"bug": -7.0,
	"lap": -7.0,
	"final_lap": -6.0,
	"finish": -5.0,
	"buzzer": -9.0,
	"bump": -7.0,
	"land": -6.0,
	"cheer": -13.0,
}
## Generated in this order: what is needed first, first.
const ORDER := ["click", "beep", "go", "engine", "skid", "boost", "bug", "checkpoint", "lap",
	"final_lap", "tick", "bump", "land", "finish", "buzzer", "cheer"]

var enabled := true
## Headless runs (scripts/measure-laps.sh) have nothing to play sound on.
var _silent := DisplayServer.get_name() == "headless"

var _streams: Dictionary = {}
var _players: Dictionary = {}
var _pending: Array = []
var _rng := RandomNumberGenerator.new()
var _role := "player"
var _engine_pitch := 0.55
var _engine_level := 0.0
var _skid_level := 0.0
## Sound -> how far into its current go round a continuous sound is, in the sound's own time.
var _loop_clock: Dictionary = {}
## Sound -> how long a continuous sound has been asked to be silent, in seconds.
var _loop_quiet: Dictionary = {}
## Kept alive for as long as the page listens for it being hidden.
var _on_hidden: JavaScriptObject


func _ready() -> void:
	_rng.seed = 20261124
	if _silent:
		enabled = false
		set_process(false)
		return
	_pending = ORDER.duplicate()
	if OS.has_feature("web"):
		# A hidden tab stops the game loop but not looping sounds: silence them on the way out.
		_on_hidden = JavaScriptBridge.create_callback(_visibility_changed)
		var document: Variant = JavaScriptBridge.get_interface("document")
		document.addEventListener("visibilitychange", _on_hidden)


func _process(_delta: float) -> void:
	if _pending.is_empty():
		set_process(false)
		return
	var sound: String = _pending.pop_front()
	_streams[sound] = _make(sound)


## Reads whether sound was on last time. Players and the big screen remember it separately.
func load_preference(role: String, default_on: bool) -> void:
	_role = role
	enabled = default_on and not _silent
	if _silent or not OS.has_feature("web"):
		return
	var stored: Variant = JavaScriptBridge.eval(
		"(function(){try{return window.localStorage.getItem('%s')}catch(e){return null}})()" % (STORAGE_KEY % _role), true)
	if stored is String:
		enabled = stored == "on"


func set_enabled(on: bool) -> void:
	enabled = on and not _silent
	if not on:
		for player: AudioStreamPlayer in _players.values():
			player.stop()
		_engine_level = 0.0
		_skid_level = 0.0
	if OS.has_feature("web"):
		JavaScriptBridge.eval("(function(){try{window.localStorage.setItem('%s','%s')}catch(e){}})()"
			% [STORAGE_KEY % _role, "on" if on else "off"], true)


## Plays a one-shot sound. `volume_db` is added to its usual level.
func play(sound: String, volume_db := 0.0, pitch := 1.0) -> void:
	if not enabled or not _streams.has(sound):
		return
	var player := _player(sound)
	player.volume_db = float(LEVELS.get(sound, -9.0)) + volume_db
	player.pitch_scale = pitch
	player.play()


## Called every frame with the player's car. The motor runs while `running`; its pitch follows
## the speed, and the tyres squeal with `skid` (0 to 1).
func update_car(speed: float, throttle: float, boosted: bool, skid: float, running: bool, delta: float) -> void:
	var motor := 0.0
	var squeal := 0.0
	if enabled and running:
		var pace := clampf(absf(speed) / 26.0, 0.0, 1.6)
		motor = 0.4 + 0.35 * maxf(throttle, 0.0) + 0.25 * minf(pace, 1.0)
		squeal = skid
		var pitch := 0.55 + 0.7 * pace + (0.12 if boosted else 0.0)
		_engine_pitch = lerpf(_engine_pitch, pitch, 1.0 - exp(-6.0 * delta))
	_engine_level = move_toward(_engine_level, motor, delta * 2.5)
	_skid_level = move_toward(_skid_level, squeal, delta * (8.0 if squeal > _skid_level else 4.0))
	_set_loop("engine", _engine_level, -13.0, _engine_pitch, delta)
	_set_loop("skid", _skid_level, -12.0, 1.0, delta)


func _player(sound: String) -> AudioStreamPlayer:
	var player: AudioStreamPlayer = _players.get(sound)
	if player == null:
		player = AudioStreamPlayer.new()
		player.stream = _streams[sound]
		player.max_polyphony = 3
		add_child(player)
		_players[sound] = player
	return player


func _set_loop(sound: String, level: float, base_db: float, pitch: float, delta: float) -> void:
	var player: AudioStreamPlayer = _players.get(sound)
	if level < 0.02:
		# A short lull (a skid flickering on and off) keeps the sound going, silently; only a
		# real pause stops it. Otherwise it would restart from its soft start every few frames.
		var quiet := float(_loop_quiet.get(sound, 0.0)) + delta
		_loop_quiet[sound] = quiet
		if quiet > 0.5 or not _loop_clock.has(sound):
			if player and _loop_clock.has(sound):
				player.stop()
			_loop_clock.erase(sound)
			return
		level = 0.0
	else:
		_loop_quiet[sound] = 0.0
	if not _streams.has(sound):
		return
	player = _player(sound)
	# Only touch what changed: on the web each change is a call into the browser.
	var db := base_db + linear_to_db(maxf(level, 0.0001))
	if absf(player.volume_db - db) > 0.25:
		player.volume_db = db
	if absf(player.pitch_scale - pitch) > 0.01:
		player.pitch_scale = pitch
	# Start the next go round just before this one ends; playing faster gets there sooner.
	# Timed here rather than asked of the player: in the browser it can report "not playing"
	# for a moment right after it was started.
	var clock := float(_loop_clock.get(sound, LOOP_SECONDS)) + delta * player.pitch_scale
	if clock >= LOOP_SECONDS - LOOP_OVERLAP:
		player.play()
		clock = 0.0
	_loop_clock[sound] = clock


func _visibility_changed(_args: Array) -> void:
	var document: Variant = JavaScriptBridge.get_interface("document")
	if bool(document.hidden):
		for sound: String in ["engine", "skid"]:
			var player: AudioStreamPlayer = _players.get(sound)
			if player:
				player.stop()
		_loop_clock.clear()
		_engine_level = 0.0
		_skid_level = 0.0


# --- making the sounds ------------------------------------------------------------------------------

func _make(sound: String) -> AudioStreamWAV:
	match sound:
		"engine":
			return _engine_loop()
		"skid":
			return _skid_loop()
		"click":
			return _click()
		"beep":
			return _beep(784.0, 0.17, 0.11, 60.0)
		"go":
			return _beep(1568.0, 0.6, 0.25, 9.0)
		"tick":
			return _beep(1046.5, 0.07, 0.02, 80.0)
		"checkpoint":
			return _notes([[0.0, 1174.7], [0.06, 1568.0]], 0.24, 22.0, 0.0)
		"lap":
			return _bells([[0.0, 1318.5], [0.09, 1975.5]], 0.85)
		"final_lap":
			return _notes([[0.0, 1046.5], [0.08, 1318.5], [0.16, 1568.0], [0.24, 2093.0]], 1.0, 7.0, 3.0)
		"boost":
			return _boost()
		"bug":
			return _bug()
		"finish":
			return _fanfare()
		"buzzer":
			return _buzzer()
		"bump":
			return _bump()
		"land":
			return _land()
		"cheer":
			return _cheer()
	return null


## The RC motor: a buzzy whine with a little gear grit. Its pitch follows the car's speed.
func _engine_loop() -> AudioStreamWAV:
	# One cycle of the waveform, worked out once, then repeated with the grit on top.
	var period := 96
	var weights := [1.0, 0.55, 0.42, 0.3, 0.2, 0.34, 0.12, 0.1]
	var cycle := PackedFloat32Array()
	cycle.resize(period)
	for i in period:
		var phase := TAU * float(i) / period
		for h in weights.size():
			cycle[i] += float(weights[h]) * sin(phase * (h + 1))
	var samples := _buffer(LOOP_SECONDS, RATE)
	for i in samples.size():
		samples[i] = cycle[i % period] * (1.0 + 0.14 * sin(TAU * 25.0 * float(i) / RATE))
	return _wav(_soft_ends(_normalize(samples, 0.8), int(LOOP_OVERLAP * RATE)), RATE)


## Tyre squeal: a wavering tone, about 950 Hz wobbling 8 times a second, over band-passed hiss.
func _skid_loop() -> AudioStreamWAV:
	var samples := _buffer(LOOP_SECONDS, RATE)
	var low := 0.0
	var lower := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var noise := _rng.randf_range(-1.0, 1.0)
		low += 0.45 * (noise - low)
		lower += 0.06 * (noise - lower)
		var squeal := sin(TAU * 950.0 * t + 2.2 * sin(TAU * 8.0 * t))
		samples[i] = (low - lower) * 0.9 + squeal * 0.35
	return _wav(_soft_ends(_normalize(samples, 0.7), int(LOOP_OVERLAP * RATE)), RATE)


func _click() -> AudioStreamWAV:
	var samples := _buffer(0.06, RATE)
	for i in samples.size():
		var t := float(i) / RATE
		samples[i] = sin(TAU * 1500.0 * t) * exp(-t * 90.0) + _rng.randf_range(-0.3, 0.3) * exp(-t * 300.0)
	return _wav(_normalize(samples, 0.8), RATE)


## A clean electronic beep: held for `hold` seconds, then dying away at `decay` per second.
func _beep(frequency: float, seconds: float, hold: float, decay: float) -> AudioStreamWAV:
	var samples := _buffer(seconds, RATE)
	for i in samples.size():
		var t := float(i) / RATE
		var envelope := minf(t / 0.004, 1.0) * (1.0 if t < hold else exp(-(t - hold) * decay))
		samples[i] = (sin(TAU * frequency * t) + 0.25 * sin(TAU * frequency * 3.0 * t)
			+ 0.3 * sin(TAU * frequency * 0.5 * t)) * envelope
	return _wav(_normalize(samples, 0.8), RATE)


## Quick bright notes, each [start, frequency]; the last one rings `last_decay` per second
## (0: like the others).
func _notes(notes: Array, seconds: float, decay: float, last_decay: float) -> AudioStreamWAV:
	var samples := _buffer(seconds, RATE)
	for i in samples.size():
		var t := float(i) / RATE
		var value := 0.0
		for n in notes.size():
			var start := float(notes[n][0])
			if t < start:
				continue
			var u := t - start
			var frequency := float(notes[n][1])
			var rate := last_decay if n == notes.size() - 1 and last_decay > 0.0 else decay
			value += (sin(TAU * frequency * u) + 0.3 * sin(TAU * frequency * 3.0 * u)) * minf(u / 0.003, 1.0) * exp(-u * rate)
		samples[i] = value
	return _wav(_normalize(samples, 0.8), RATE)


## A two-note bell chime, for a lap.
func _bells(notes: Array, seconds: float) -> AudioStreamWAV:
	var samples := _buffer(seconds, RATE)
	for i in samples.size():
		var t := float(i) / RATE
		var value := 0.0
		for note: Array in notes:
			var start := float(note[0])
			if t < start:
				continue
			var u := t - start
			var f := float(note[1])
			value += (sin(TAU * f * u) + 0.35 * sin(TAU * 2.01 * f * u) + 0.18 * sin(TAU * 3.0 * f * u)) \
				* minf(u / 0.003, 1.0) * exp(-u * 5.5)
		samples[i] = value
	return _wav(_normalize(samples, 0.8), RATE)


## Cache hit: a rising zap with a whoosh and a sparkle at the top.
func _boost() -> AudioStreamWAV:
	var samples := _buffer(0.65, RATE)
	var sweep := 0.45
	var start := 240.0
	var rise := 6.0
	var air := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		# Exponential sweep from `start` to `start * rise` over `sweep` seconds, then held.
		var phase := TAU * start * sweep / log(rise) * (pow(rise, minf(t, sweep) / sweep) - 1.0)
		if t > sweep:
			phase += TAU * start * rise * (t - sweep)
		var saw := sin(phase) + 0.5 * sin(2.0 * phase) + 0.33 * sin(3.0 * phase) + 0.25 * sin(4.0 * phase)
		var envelope := minf(t / 0.015, 1.0) * (1.0 if t < 0.35 else exp(-(t - 0.35) * 9.0))
		air += (0.05 + 0.5 * minf(t / 0.4, 1.0)) * (_rng.randf_range(-1.0, 1.0) - air)
		var whoosh := air * sin(PI * minf(t / 0.5, 1.0))
		var sparkle := 0.0
		if t >= 0.3:
			sparkle += 0.5 * sin(TAU * 2093.0 * t) * exp(-(t - 0.3) * 14.0)
		if t >= 0.36:
			sparkle += 0.35 * sin(TAU * 3136.0 * t) * exp(-(t - 0.36) * 14.0)
		samples[i] = saw * envelope * 0.55 + whoosh * 0.6 + sparkle
	return _wav(_normalize(samples, 0.85), RATE)


## Bug: a falling, stuttering, bit-crushed buzz.
func _bug() -> AudioStreamWAV:
	var samples := _buffer(0.45, RATE)
	var seconds := 0.45
	var start := 210.0
	var ratio := 65.0 / 210.0
	var smooth := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var phase := TAU * start * seconds / log(ratio) * (pow(ratio, t / seconds) - 1.0)
		var square := 1.0 if sin(phase) >= 0.0 else -1.0
		var gate := 1.0 if fmod(t * 26.0, 1.0) < 0.62 else 0.2
		var envelope := minf(t / 0.005, 1.0) * exp(-t * 3.5)
		var crushed := roundf(square * gate * envelope * 5.0) / 5.0
		smooth += 0.55 * (crushed - smooth)
		samples[i] = smooth + _rng.randf_range(-0.6, 0.6) * exp(-t * 60.0)
	return _wav(_normalize(samples, 0.75), RATE)


## The finish: a short brass fanfare up to a held chord.
func _fanfare() -> AudioStreamWAV:
	# [start, frequency, length, loudness]
	var notes := [
		[0.0, 523.25, 0.13, 1.0], [0.14, 659.25, 0.13, 1.0], [0.28, 783.99, 0.13, 1.0],
		[0.42, 1046.5, 1.0, 1.0], [0.42, 783.99, 1.0, 0.45], [0.42, 659.25, 1.0, 0.35],
	]
	var samples := _buffer(1.7, LOW_RATE)
	for i in samples.size():
		var t := float(i) / LOW_RATE
		var value := 0.0
		for note: Array in notes:
			var start := float(note[0])
			if t < start:
				continue
			var u := t - start
			var f := float(note[1])
			var length := float(note[2])
			# A little vibrato on the held notes.
			var phase := TAU * f * u + (0.006 * f / 5.5 * (1.0 - cos(TAU * 5.5 * u)) if length > 0.5 else 0.0)
			var tone := sin(phase) + 0.6 * sin(2.0 * phase) + 0.4 * sin(3.0 * phase) + 0.25 * sin(4.0 * phase)
			var envelope := minf(u / 0.02, 1.0) * (1.0 if u < length else exp(-(u - length) * 12.0))
			if length > 0.5:
				envelope *= exp(-u * 0.6)
			value += tone * envelope * float(note[3])
		samples[i] = value
	return _wav(_normalize(samples, 0.8), LOW_RATE)


## Time's up: a low, beating buzzer.
func _buzzer() -> AudioStreamWAV:
	var samples := _buffer(0.8, LOW_RATE)
	var low := 0.0
	for i in samples.size():
		var t := float(i) / LOW_RATE
		var a := 1.0 if sin(TAU * 150.0 * t) >= 0.0 else -1.0
		var b := 1.0 if sin(TAU * 156.0 * t) >= 0.0 else -1.0
		low += 0.3 * ((a + b) * 0.5 - low)
		samples[i] = low * minf(t / 0.01, 1.0) * (1.0 if t < 0.6 else exp(-(t - 0.6) * 15.0))
	return _wav(_normalize(samples, 0.7), LOW_RATE)


## Hitting the Armco: a thud with a metallic clank.
func _bump() -> AudioStreamWAV:
	var samples := _buffer(0.25, LOW_RATE)
	var low := 0.0
	for i in samples.size():
		var t := float(i) / LOW_RATE
		low += 0.08 * (_rng.randf_range(-1.0, 1.0) - low)
		var clank := 0.5 * sin(TAU * 380.0 * t) + 0.3 * sin(TAU * 977.0 * t) + 0.2 * sin(TAU * 1520.0 * t)
		samples[i] = low * 6.0 * exp(-t * 30.0) + clank * exp(-t * 22.0)
	return _wav(_normalize(samples, 0.85), LOW_RATE)


## Landing a jump: a falling low thump.
func _land() -> AudioStreamWAV:
	var samples := _buffer(0.4, LOW_RATE)
	var phase := 0.0
	var low := 0.0
	for i in samples.size():
		var t := float(i) / LOW_RATE
		phase += TAU * (40.0 + 80.0 * exp(-t * 10.0)) / LOW_RATE
		low += 0.05 * (_rng.randf_range(-1.0, 1.0) - low)
		samples[i] = sin(phase) * exp(-t * 8.0) + low * 5.0 * exp(-t * 25.0)
	return _wav(_normalize(samples, 0.9), LOW_RATE)


## A crowd roaring as a car goes past: babbling hiss with a few voices whooping on top.
func _cheer() -> AudioStreamWAV:
	var seconds := 2.2
	var samples := _buffer(seconds, LOW_RATE)
	var voices: Array = []
	for _voice in 7:
		voices.append([_rng.randf_range(0.0, 0.7), _rng.randf_range(0.5, 1.1), _rng.randf_range(300.0, 650.0)])
	var low := 0.0
	var lower := 0.0
	for i in samples.size():
		var t := float(i) / LOW_RATE
		var noise := _rng.randf_range(-1.0, 1.0)
		low += 0.3 * (noise - low)
		lower += 0.04 * (noise - lower)
		var babble := 0.7 + 0.3 * sin(TAU * 6.7 * t) * sin(TAU * 2.9 * t + 1.3)
		var envelope := smoothstep(0.0, 0.35, t) * (1.0 if t < 1.3 else exp(-(t - 1.3) * 3.0))
		var whoops := 0.0
		for voice: Array in voices:
			var u := t - float(voice[0])
			var length := float(voice[1])
			if u < 0.0 or u > length:
				continue
			# Each voice slides up by a quarter as it goes: "woooo!"
			var phase := TAU * float(voice[2]) * (u + 0.125 * u * u / length)
			whoops += (sin(phase) + 0.4 * sin(2.0 * phase) + 0.2 * sin(3.0 * phase)) * sin(PI * u / length)
		samples[i] = (low - lower) * babble * envelope * 2.2 + whoops * 0.09 * envelope
	return _wav(_normalize(samples, 0.8), LOW_RATE)


# --- helpers ----------------------------------------------------------------------------------------

static func _buffer(seconds: float, rate: int) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(seconds * rate))
	return samples


static func _normalize(samples: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var loudest := 0.0001
	for value in samples:
		loudest = maxf(loudest, absf(value))
	var gain := peak / loudest
	for i in samples.size():
		samples[i] *= gain
	return samples


## Fades the first and last `fade` samples in and out, so overlapping copies blend.
static func _soft_ends(samples: PackedFloat32Array, fade: int) -> PackedFloat32Array:
	var count := samples.size()
	for i in fade:
		var k := sin(float(i) / fade * PI * 0.5)
		samples[i] *= k
		samples[count - 1 - i] *= k
	return samples


static func _wav(samples: PackedFloat32Array, rate: int) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav
