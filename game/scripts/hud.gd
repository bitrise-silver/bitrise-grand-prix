extends CanvasLayer
## Everything drawn over the 3D view: position and standings on the left, lap and times on
## the right, the driving controls, the LED countdown, the track intro, pop-up messages and
## the start and results panels.
##
## The project stretches the canvas so its short side is always 720 units, which keeps the
## controls the same physical size on every phone. The game is played in landscape; held
## upright, a phone shows a "turn your phone" card instead.
##
## Panels pop in and fade out, buttons squash when pressed, and a fade hides the camera
## jumping back to the grid between runs.

signal primary_pressed
signal skip_requested
## The speaker button was tapped.
signal sound_toggled(on: bool)
## Any other button was pressed; for the click sound.
signal ui_clicked

const COL_PANEL := Color(0.098, 0.035, 0.153, 0.80)
const COL_ROW := Color(0.098, 0.035, 0.153, 0.66)
const COL_ACCENT := Color("#11bba9")
const COL_ON_ACCENT := Color("#04302b")
const COL_TEXT := Color("#f6f4f6")
const COL_DIM := Color("#c9c1cd")
const COL_WARN := Color("#ff8091")
const COL_LED := Color("#f9cc15")
const COL_FADE := Color("#1d0a2b")
const MARGIN := 26.0
## The remaining time only appears once it is worth worrying about.
const TIME_WARNING_MS := 15_000
const TOWER_ROWS := 4

## -1 (left) to 1 (right), from the steering stick.
var steer := 0.0
## 1 while the accelerate button is held, -1 for reverse (which brakes first), otherwise 0.
var throttle := 0.0
var sticks_enabled := false:
	set(value):
		sticks_enabled = value
		if not value:
			_release_all()
		if _steer_stick:
			var shown := value and not spectating
			_steer_stick.visible = shown
			_gas_button.visible = shown
			_reverse_button.visible = shown
var spectating := false

var _font: FontVariation
var _root: Control
var _fade: ColorRect
var _fade_tween: Tween
var _flash: ColorRect
var _vignette: TextureRect
var _sound_button: SoundButton
var _time := 0.0
var _count_tween: Tween
## Whether a panel is meant to be up; true from show until hide, whatever the animation is doing.
var _panel_open := false
var _left: VBoxContainer
var _pos_number: Label
var _pos_total: Label
var _tower: VBoxContainer
var _gap_label: Label
var _right: VBoxContainer
var _lap_number: Label
var _lap_total: Label
var _time_value: Label
var _best_value: Label
var _warning_label: Label
var _status_label: Label
var _banner: Label
var _banner_tween: Tween
var _toast: PanelContainer
var _toast_label: Label
var _toast_style: StyleBoxFlat
var _toast_tween: Tween
var _led: LedBoard
var _intro: Control
var _intro_bars: Array[ColorRect] = []
var _intro_title: Label
var _intro_laps: Label
var _intro_tween: Tween
var _panel: PanelContainer
var _panel_title: Label
var _panel_subtitle: Label
var _panel_note: Label
var _panel_button: Button
var _results: PanelContainer
var _results_session: Label
var _results_time: Label
var _results_subtitle: Label
var _results_note: Label
var _results_rows: VBoxContainer
var _results_button: Button
var _portrait: Control
var _steer_stick: TouchStick
var _gas_button: PedalButton
var _reverse_button: PedalButton
var _steer_touch := -1
## Touch index -> the pedal that finger is on: "gas", "reverse" or "" when it slid off both.
var _pedal_touches: Dictionary = {}


## The steering stick. Purely a drawing; the HUD feeds it the value to show.
class TouchStick extends Control:
	const RADIUS := 108.0
	const TRAVEL := 78.0
	var value := 0.0:
		set(next):
			value = next
			queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2.ONE * (RADIUS * 2.0 + 16.0)
		size = custom_minimum_size

	func center() -> Vector2:
		return global_position + size * 0.5

	func _draw() -> void:
		var c := size * 0.5
		var axis := Vector2.RIGHT
		draw_circle(c, RADIUS, Color(0.1, 0.04, 0.16, 0.35))
		draw_arc(c, RADIUS, 0.0, TAU, 64, Color(1, 1, 1, 0.55), 4.0, true)
		draw_line(c - axis * TRAVEL, c + axis * TRAVEL, Color(1, 1, 1, 0.22), 10.0, true)
		for direction in [-1.0, 1.0]:
			var tip: Vector2 = c + axis * (RADIUS - 12.0) * direction
			var side := Vector2(0, 11.0)
			var base: Vector2 = tip - axis * 16.0 * direction
			draw_colored_polygon(PackedVector2Array([tip, base + side, base - side]), Color(1, 1, 1, 0.5))
		var knob := c + axis * value * TRAVEL
		draw_circle(knob, 44.0, Color(0.067, 0.733, 0.663, 0.92))
		draw_arc(knob, 44.0, 0.0, TAU, 48, Color(1, 1, 1, 0.9), 3.0, true)


## A round pedal: accelerate (arrow up) or reverse (arrow down). A ring ripples out from it
## each time it is pressed.
class PedalButton extends Control:
	var radius := 88.0
	var reverse := false
	var pressed := false:
		set(next):
			if pressed != next:
				pressed = next
				if next:
					_ripple = 0.0
				queue_redraw()
	var _ripple := 1.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		if _ripple < 1.0:
			_ripple = minf(1.0, _ripple + delta / 0.35)
			queue_redraw()

	func setup(button_radius: float, is_reverse: bool) -> void:
		radius = button_radius
		reverse = is_reverse
		custom_minimum_size = Vector2.ONE * radius * 2.0
		size = custom_minimum_size

	func center() -> Vector2:
		return global_position + size * 0.5

	func _draw() -> void:
		var c := size * 0.5
		var drawn := radius * (0.93 if pressed else 1.0)
		var fill := Color(0.067, 0.733, 0.663, 0.95 if pressed else 0.72)
		var arrow := Color(0.0, 0.16, 0.14, 0.9)
		if reverse:
			fill = Color(1, 1, 1, 0.36 if pressed else 0.14)
			arrow = Color(1, 1, 1, 0.9)
		if _ripple < 1.0:
			var eased := 1.0 - pow(1.0 - _ripple, 3.0)
			draw_arc(c, radius * (1.0 + 0.4 * eased), 0.0, TAU, 64, Color(1, 1, 1, 0.55 * (1.0 - _ripple)), 5.0, true)
		draw_circle(c, drawn, fill)
		draw_arc(c, drawn, 0.0, TAU, 64, Color(1, 1, 1, 0.95 if pressed else 0.6), 4.0, true)
		var direction := Vector2.DOWN if reverse else Vector2.UP
		var reach := radius * 0.42
		var tip := c + direction * reach * 0.8
		var base := c - direction * reach * 0.5
		var side := Vector2(reach * 0.85, 0)
		draw_colored_polygon(PackedVector2Array([tip, base + side, base - side]), arrow)


## A round speaker button that turns the sound on and off.
class SoundButton extends Control:
	signal toggled_on(on: bool)
	var on := true:
		set(next):
			on = next
			queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		custom_minimum_size = Vector2(64, 64)
		size = custom_minimum_size

	func _gui_input(event: InputEvent) -> void:
		var click := event as InputEventMouseButton
		if click and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			on = not on
			toggled_on.emit(on)
			accept_event()
			pivot_offset = size * 0.5
			scale = Vector2.ONE * 0.8
			create_tween().tween_property(self, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	func _draw() -> void:
		var c := size * 0.5
		var ink := Color(1, 1, 1, 0.92)
		draw_circle(c, 30.0, Color(0.098, 0.035, 0.153, 0.66))
		draw_arc(c, 30.0, 0.0, TAU, 48, Color(1, 1, 1, 0.35), 2.0, true)
		draw_rect(Rect2(c + Vector2(-15, -6), Vector2(7, 12)), ink)
		draw_colored_polygon(PackedVector2Array([c + Vector2(-8, -6), c + Vector2(1, -14), c + Vector2(1, 14), c + Vector2(-8, 6)]), ink)
		if on:
			draw_arc(c + Vector2(3, 0), 7.0, -0.9, 0.9, 12, ink, 3.0, true)
			draw_arc(c + Vector2(3, 0), 13.0, -0.9, 0.9, 16, ink, 3.0, true)
		else:
			var cross := Color("#ff8091")
			draw_line(c + Vector2(7, -7), c + Vector2(18, 4), cross, 3.5, true)
			draw_line(c + Vector2(7, 4), c + Vector2(18, -7), cross, 3.5, true)


## A dot-matrix LED board for the countdown: 3, 2, 1, GO.
class LedBoard extends Control:
	const DOT := 20.0
	const PAD := 28.0
	## 5x7 glyphs, one string per row, "#" lit.
	const GLYPHS := {
		"1": ["..#..", ".##..", "#.#..", "..#..", "..#..", "..#..", "#####"],
		"2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
		"3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
		"G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
		"O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
	}
	var text := ""
	var color := Color("#f9cc15")
	## 0..1: how much of the glyph has lit up, sweeping left to right.
	var reveal := 1.0:
		set(next):
			reveal = next
			queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func columns() -> int:
		return text.length() * 6 - 1

	func board_size() -> Vector2:
		return Vector2(columns() * DOT + PAD * 2.0, 7 * DOT + PAD * 2.0)

	func _draw() -> void:
		var size_now := board_size()
		var frame := StyleBoxFlat.new()
		frame.bg_color = Color(0.06, 0.03, 0.09, 0.92)
		frame.set_corner_radius_all(22)
		frame.set_border_width_all(4)
		frame.border_color = Color(0.25, 0.14, 0.33, 1.0)
		frame.shadow_color = Color(0, 0, 0, 0.35)
		frame.shadow_size = 12
		draw_style_box(frame, Rect2(Vector2.ZERO, size_now))
		var lit_columns := reveal * columns()
		for index in text.length():
			var glyph: Array = GLYPHS.get(text[index], [])
			for row in glyph.size():
				var line: String = glyph[row]
				for column in 5:
					var x := index * 6 + column
					var center := Vector2(PAD + (x + 0.5) * DOT, PAD + (row + 0.5) * DOT)
					var lit := line[column] == "#" and x < lit_columns
					if lit:
						draw_circle(center, DOT * 0.85, Color(color.r, color.g, color.b, 0.18))
						draw_circle(center, DOT * 0.42, color)
						draw_circle(center, DOT * 0.18, color.lightened(0.6))
					else:
						draw_circle(center, DOT * 0.32, Color(1, 1, 1, 0.07))


## A phone turning on its side, for the "please hold it in landscape" card.
class RotateHint extends Control:
	var _time := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(180, 180)

	func _process(delta: float) -> void:
		if is_visible_in_tree():
			_time += delta
			queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var t := clampf((fmod(_time, 2.4) - 0.6) / 0.8, 0.0, 1.0)
		var angle := t * t * (3.0 - 2.0 * t) * PI * 0.5
		draw_set_transform(c, -angle, Vector2.ONE)
		var body := Rect2(Vector2(-40, -70), Vector2(80, 140))
		var frame := StyleBoxFlat.new()
		frame.bg_color = Color(0, 0, 0, 0)
		frame.set_border_width_all(6)
		frame.border_color = Color("#f6f4f6")
		frame.set_corner_radius_all(14)
		draw_style_box(frame, body)
		draw_circle(Vector2(0, 54), 5.0, Color("#f6f4f6"))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _ready() -> void:
	_font = FontVariation.new()
	_font.base_font = ThemeDB.fallback_font
	_font.variation_embolden = 0.9
	# A forward lean, for a bit of speed.
	_font.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.16, 1), Vector2.ZERO)

	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	theme.default_font = _font
	theme.default_font_size = 28
	_root.theme = theme
	add_child(_root)

	_build_overlays()
	_build_left()
	_build_right()

	# Only speaks up when something is wrong, such as a lost connection.
	_status_label = _label(24, COL_WARN)
	_status_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_status_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.position.y = MARGIN + 66.0
	_root.add_child(_status_label)

	# Sound on/off: top centre while driving (clear of both thumbs), top right on the big screen.
	_sound_button = SoundButton.new()
	if spectating:
		_sound_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		_sound_button.position = Vector2(-MARGIN - _sound_button.size.x, MARGIN)
	else:
		_sound_button.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		_sound_button.position = Vector2(-_sound_button.size.x * 0.5, MARGIN - 8.0)
	_sound_button.toggled_on.connect(func(on: bool) -> void: sound_toggled.emit(on))
	_root.add_child(_sound_button)

	_banner = _label(110, COL_TEXT)
	_banner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_banner.offset_bottom = -220.0
	_banner.add_theme_constant_override("outline_size", 22)
	_banner.modulate.a = 0.0
	_root.add_child(_banner)

	_led = LedBoard.new()
	_led.modulate.a = 0.0
	_root.add_child(_led)

	_build_toast()
	_build_controls()
	_build_intro()
	_build_panel()
	_build_results()
	_build_portrait()
	sticks_enabled = false
	if spectating:
		_left.visible = false
		_right.visible = false
		_status_label.visible = false


func _process(delta: float) -> void:
	_time += delta
	if _portrait:
		_portrait.visible = not spectating and _root.size.y > _root.size.x * 1.05
	# Panels scale about their middle; their size is only known once laid out.
	_panel.pivot_offset = _panel.size * 0.5
	_results.pivot_offset = _results.size * 0.5
	# The main button breathes gently while it waits to be pressed.
	var glow := 1.0 + 0.12 * (0.5 + 0.5 * sin(_time * 4.0))
	for button in [_panel_button, _results_button]:
		(button as Button).modulate = Color(glow, glow, glow) if (button as Button).visible else Color.WHITE


# --- building -----------------------------------------------------------------------------------

func _panel_style(color: Color, radius := 10, padding := Vector4(14, 6, 14, 6)) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.content_margin_left = padding.x
	style.content_margin_top = padding.y
	style.content_margin_right = padding.z
	style.content_margin_bottom = padding.w
	return style


## Full-screen layers over the 3D view but under the rest of the HUD: the fade used for
## transitions (opaque until the world is built), a flash, and a coloured vignette for boosts
## and bugs.
func _build_overlays() -> void:
	_vignette = TextureRect.new()
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	gradient.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 0), Color(1, 1, 1, 1)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.05, 0.5)
	texture.width = 128
	texture.height = 128
	_vignette.texture = texture
	_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.modulate = Color(1, 1, 1, 0)
	_root.add_child(_vignette)

	_flash = ColorRect.new()
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.color = Color(1, 1, 1, 0)
	_root.add_child(_flash)

	_fade = ColorRect.new()
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.color = COL_FADE
	_root.add_child(_fade)


## Position, standings tower and the gap to the car ahead, top left.
func _build_left() -> void:
	_left = VBoxContainer.new()
	_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left.add_theme_constant_override("separation", 6)
	_left.position = Vector2(MARGIN, MARGIN - 12.0)
	_root.add_child(_left)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	_left.add_child(head)
	_pos_number = _label(92, COL_TEXT)
	_pos_number.text = "–"
	head.add_child(_pos_number)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", -10)
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_child(stack)
	var caption := _label(24, COL_DIM)
	caption.text = "POS"
	stack.add_child(caption)
	_pos_total = _label(40, COL_TEXT)
	stack.add_child(_pos_total)

	_tower = VBoxContainer.new()
	_tower.add_theme_constant_override("separation", 4)
	_left.add_child(_tower)
	_gap_label = _label(22, COL_DIM)
	_left.add_child(_gap_label)
	_left.visible = false


## Lap counter and times, top right.
func _build_right() -> void:
	_right = VBoxContainer.new()
	_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right.add_theme_constant_override("separation", 6)
	_right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_right.position = Vector2(-MARGIN, MARGIN - 12.0)
	_right.alignment = BoxContainer.ALIGNMENT_BEGIN
	_root.add_child(_right)

	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_END
	head.add_theme_constant_override("separation", 6)
	_right.add_child(head)
	_lap_number = _label(92, COL_TEXT)
	head.add_child(_lap_number)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", -10)
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_child(stack)
	var caption := _label(24, COL_DIM)
	caption.text = "LAP"
	stack.add_child(caption)
	_lap_total = _label(40, COL_TEXT)
	stack.add_child(_lap_total)

	_time_value = _time_row("TIME")
	_best_value = _time_row("BEST")
	_warning_label = _label(28, COL_WARN)
	_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_right.add_child(_warning_label)


func _time_row(caption_text: String) -> Label:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _panel_style(COL_ROW, 8, Vector4(14, 2, 14, 4)))
	row.custom_minimum_size.x = 268
	_right.add_child(row)
	var line := HBoxContainer.new()
	row.add_child(line)
	var caption := _label(22, COL_DIM)
	caption.text = caption_text
	caption.add_theme_constant_override("outline_size", 0)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(caption)
	var value := _label(30, COL_TEXT)
	value.add_theme_constant_override("outline_size", 0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(value)
	return value


func _build_toast() -> void:
	_toast = PanelContainer.new()
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_style = _panel_style(Color(0.10, 0.03, 0.16, 0.86), 36, Vector4(30, 8, 30, 10))
	_toast_style.set_border_width_all(3)
	_toast.add_theme_stylebox_override("panel", _toast_style)
	_toast.modulate.a = 0.0
	_root.add_child(_toast)
	_toast_label = _label(38, COL_TEXT)
	_toast_label.add_theme_constant_override("outline_size", 0)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_child(_toast_label)


func _build_controls() -> void:
	_steer_stick = TouchStick.new()
	_steer_stick.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_steer_stick.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_steer_stick.position = Vector2(MARGIN + 8.0, -MARGIN - 8.0 - _steer_stick.size.y)
	_root.add_child(_steer_stick)

	# Accelerate sits in the corner under the right thumb; reverse is the smaller one beside it.
	_gas_button = PedalButton.new()
	_gas_button.setup(88.0, false)
	_gas_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_gas_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_gas_button.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_gas_button.position = Vector2(-MARGIN - 8.0 - _gas_button.size.x, -MARGIN - 28.0 - _gas_button.size.y)
	_root.add_child(_gas_button)

	_reverse_button = PedalButton.new()
	_reverse_button.setup(60.0, true)
	_reverse_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_reverse_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_reverse_button.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_reverse_button.position = Vector2(
		-MARGIN - 8.0 - _gas_button.size.x - 28.0 - _reverse_button.size.x,
		-MARGIN - 8.0 - _reverse_button.size.y)
	_root.add_child(_reverse_button)


## Letterbox bars and the track's name, over the fly-over before the first countdown.
func _build_intro() -> void:
	_intro = Control.new()
	_intro.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_intro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_intro.visible = false
	_root.add_child(_intro)
	for top in [true, false]:
		var bar := ColorRect.new()
		bar.color = Color(0.03, 0.01, 0.05, 0.9)
		bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE if top else Control.PRESET_BOTTOM_WIDE)
		bar.custom_minimum_size.y = 78
		bar.offset_bottom = 78 if top else 0.0
		bar.offset_top = 0.0 if top else -78.0
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_intro.add_child(bar)
		_intro_bars.append(bar)
	var skip := _label(22, COL_DIM)
	skip.text = "TAP TO SKIP"
	skip.add_theme_constant_override("outline_size", 0)
	skip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	skip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	skip.grow_vertical = Control.GROW_DIRECTION_BEGIN
	skip.position = Vector2(-MARGIN - 150.0, -54.0)
	_intro_bars[1].add_child(skip)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.offset_bottom = -180.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_intro.add_child(center)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 22)
	center.add_child(line)
	_intro_title = _label(64, COL_TEXT)
	line.add_child(_intro_title)
	var divider := ColorRect.new()
	divider.color = COL_ACCENT
	divider.custom_minimum_size = Vector2(5, 64)
	divider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(divider)
	_intro_laps = _label(64, COL_ACCENT)
	line.add_child(_intro_laps)


func _button(text_size: int) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0, 88)
	button.add_theme_font_size_override("font_size", text_size)
	for color_name: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(color_name, COL_ON_ACCENT)
	var fills := {"normal": COL_ACCENT, "hover": COL_ACCENT.lightened(0.12), "pressed": COL_ACCENT.darkened(0.2), "focus": COL_ACCENT}
	for state_name: String in fills:
		var style := _panel_style(fills[state_name], 14, Vector4(24, 8, 24, 8))
		button.add_theme_stylebox_override(state_name, style)
	button.button_down.connect(func() -> void: _squash(button, 0.93))
	button.button_up.connect(func() -> void: _squash(button, 1.0))
	button.pressed.connect(func() -> void:
		ui_clicked.emit()
		primary_pressed.emit())
	return button


## Springs a button to `amount` of its size: in when pressed, back out when let go.
func _squash(button: Control, amount: float) -> void:
	button.pivot_offset = button.size * 0.5
	var tween := button.create_tween()
	tween.tween_property(button, "scale", Vector2.ONE * amount, 0.08 if amount < 1.0 else 0.3) \
		.set_trans(Tween.TRANS_QUAD if amount < 1.0 else Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## The small panel for start, practice and connection messages.
func _build_panel() -> void:
	var holder := CenterContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(holder)

	_panel = PanelContainer.new()
	var box := _panel_style(COL_PANEL, 22, Vector4(36, 30, 36, 32))
	box.set_border_width_all(0)
	box.border_width_top = 6
	box.border_color = COL_ACCENT
	_panel.add_theme_stylebox_override("panel", box)
	_panel.custom_minimum_size = Vector2(540, 0)
	holder.add_child(_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	_panel.add_child(column)
	_panel_title = _label(52, COL_TEXT)
	_panel_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_panel_title)
	_panel_subtitle = _label(28, COL_DIM)
	_panel_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_subtitle.add_theme_constant_override("outline_size", 0)
	column.add_child(_panel_subtitle)
	_panel_note = _label(22, COL_DIM)
	_panel_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_note.add_theme_constant_override("outline_size", 0)
	column.add_child(_panel_note)
	_panel_button = _button(40)
	column.add_child(_panel_button)
	_panel.visible = false


## Standings over the live track at the end of a run (and when a session is closed).
func _build_results() -> void:
	var holder := CenterContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(holder)

	_results = PanelContainer.new()
	_results.add_theme_stylebox_override("panel", _panel_style(Color(0.098, 0.035, 0.153, 0.72), 20, Vector4(34, 24, 34, 26)))
	_results.custom_minimum_size = Vector2(760, 0)
	holder.add_child(_results)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_results.add_child(column)

	var header := HBoxContainer.new()
	column.add_child(header)
	var heading := _label(34, COL_ACCENT)
	heading.text = "RESULTS"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	_results_session = _label(24, COL_DIM)
	_results_session.add_theme_constant_override("outline_size", 0)
	header.add_child(_results_session)
	var rule := ColorRect.new()
	rule.color = Color(1, 1, 1, 0.25)
	rule.custom_minimum_size.y = 2
	column.add_child(rule)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 18)
	column.add_child(summary)
	_results_time = _label(60, COL_TEXT)
	summary.add_child(_results_time)
	var detail := VBoxContainer.new()
	detail.alignment = BoxContainer.ALIGNMENT_CENTER
	detail.add_theme_constant_override("separation", -2)
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary.add_child(detail)
	_results_subtitle = _label(26, COL_TEXT)
	_results_subtitle.add_theme_constant_override("outline_size", 0)
	_results_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(_results_subtitle)
	_results_note = _label(22, COL_DIM)
	_results_note.add_theme_constant_override("outline_size", 0)
	detail.add_child(_results_note)

	var columns := _table_row(["POS", "", "DRIVER", "BEST LAP", "TIME"], Color(0, 0, 0, 0), COL_DIM, 20)
	column.add_child(columns)
	_results_rows = VBoxContainer.new()
	_results_rows.add_theme_constant_override("separation", 4)
	column.add_child(_results_rows)
	_results_button = _button(38)
	column.add_child(_results_button)
	_results.visible = false


## One row of the results table: position, colour bar, name, best lap, total.
func _table_row(cells: Array, background: Color, text_color: Color, text_size := 26, bar := Color(0, 0, 0, 0)) -> PanelContainer:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _panel_style(background, 8, Vector4(12, 2, 14, 3)))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	row.add_child(line)
	var widths := [52, 6, 0, 150, 150]
	for i in cells.size():
		if i == 1:
			var swatch := ColorRect.new()
			swatch.color = bar
			swatch.custom_minimum_size = Vector2(6, text_size + 4)
			swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.add_child(swatch)
			continue
		var cell := _label(text_size, text_color)
		cell.add_theme_constant_override("outline_size", 0)
		cell.text = str(cells[i])
		cell.clip_text = true
		if widths[i] > 0:
			cell.custom_minimum_size.x = widths[i]
		else:
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if i >= 3:
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		line.add_child(cell)
	return row


func _build_portrait() -> void:
	_portrait = ColorRect.new()
	(_portrait as ColorRect).color = Color(0.06, 0.03, 0.09, 0.97)
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_portrait.mouse_filter = Control.MOUSE_FILTER_STOP
	_portrait.visible = false
	_root.add_child(_portrait)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait.add_child(center)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(column)
	var hint := RotateHint.new()
	hint.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(hint)
	var title := _label(40, COL_TEXT)
	title.text = "Turn your phone sideways"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var note := _label(24, COL_DIM)
	note.text = "Bitrise Grand Prix is played in landscape."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_constant_override("outline_size", 0)
	column.add_child(note)


# --- what the game tells the HUD ----------------------------------------------------------------

## `time_left_ms` is negative when no run is in progress; `best_lap_ms` is 0 before the first lap.
func set_race_readout(lap: int, laps_total: int, elapsed_ms: int, time_left_ms: int, best_lap_ms := 0) -> void:
	_lap_number.text = str(mini(lap, laps_total))
	_lap_total.text = "/%d" % laps_total
	_time_value.text = format_time(elapsed_ms)
	_best_value.text = format_time(best_lap_ms) if best_lap_ms > 0 else "–:––.––"
	var warn := time_left_ms >= 0 and time_left_ms <= TIME_WARNING_MS
	_warning_label.visible = warn
	if warn:
		_warning_label.text = "%d s LEFT" % int(ceil(time_left_ms / 1000.0))


func set_status(text: String) -> void:
	_status_label.text = text


func set_sound(on: bool) -> void:
	_sound_button.on = on


## Fades in from the start-up colour once there is a world to show.
func reveal() -> void:
	if _fade_tween and _fade_tween.is_running():
		return
	_fade_tween = create_tween()
	_fade_tween.tween_property(_fade, "modulate:a", 0.0, 0.6).set_ease(Tween.EASE_OUT)
	_fade_tween.tween_callback(func() -> void: _fade.visible = false)


## Fades the 3D view out, calls `mid` while nothing can be seen, then fades back in. Hides the
## camera jumping, such as going back to the grid for another run.
func transition(mid: Callable) -> void:
	if _fade_tween:
		_fade_tween.kill()
	_fade.visible = true
	_fade_tween = create_tween()
	_fade_tween.tween_property(_fade, "modulate:a", 1.0, 0.22).set_ease(Tween.EASE_IN)
	_fade_tween.tween_callback(mid)
	_fade_tween.tween_interval(0.08)
	_fade_tween.tween_property(_fade, "modulate:a", 0.0, 0.4).set_ease(Tween.EASE_OUT)
	_fade_tween.tween_callback(func() -> void: _fade.visible = false)


## A quick full-screen flash, for GO.
func flash(color: Color, strength := 0.25) -> void:
	_flash.color = Color(color.r, color.g, color.b, strength)
	create_tween().tween_property(_flash, "color:a", 0.0, 0.35).set_ease(Tween.EASE_OUT)


## The screen's edges glow in `color` for a moment: teal for a boost, red for a bug.
func pulse_edges(color: Color, strength := 0.6) -> void:
	_vignette.modulate = Color(color.r, color.g, color.b, strength)
	var tween := create_tween()
	tween.tween_interval(0.12)
	tween.tween_property(_vignette, "modulate:a", 0.0, 0.55).set_ease(Tween.EASE_IN)


func set_track_title(track_name: String, laps: int) -> void:
	_intro_title.text = track_name.to_upper()
	_intro_laps.text = "%d LAPS" % laps


## A fresh run: no position until the first checkpoint. Practice runs have no standings at all.
func reset_run(online: bool) -> void:
	_left.visible = online and not spectating
	_pos_number.text = "–"
	_pos_total.text = ""
	_gap_label.text = ""
	for child in _tower.get_children():
		child.queue_free()


## The server's live standing: { rank, of, gapAheadMs, gapBehindMs, rows: [{ rank, name, color, you }] }.
func set_standing(standing: Dictionary) -> void:
	var rank := int(standing.get("rank", 0))
	var total := int(standing.get("of", 1))
	_pos_number.text = str(rank) if rank > 0 else "–"
	_pos_total.text = "/%d" % total

	for child in _tower.get_children():
		child.queue_free()
	for entry: Dictionary in standing.get("rows", []):
		var you: bool = entry.get("you", false)
		var row_rank := int(entry.get("rank", 0))
		var cells := [str(row_rank) if row_rank > 0 else "–", "", str(entry.get("name", ""))]
		var row := _tower_row(cells, Color(str(entry.get("color", "#9247c2"))), you)
		_tower.add_child(row)

	var ahead: Variant = standing.get("gapAheadMs", null)
	var behind: Variant = standing.get("gapBehindMs", null)
	if rank > 1 and ahead != null:
		_gap_label.text = "+%.2f s to P%d" % [float(ahead) / 1000.0, rank - 1]
		_gap_label.add_theme_color_override("font_color", COL_DIM)
	elif rank == 1 and behind != null:
		_gap_label.text = "LEADING by %.2f s" % (float(behind) / 1000.0)
		_gap_label.add_theme_color_override("font_color", COL_ACCENT)
	else:
		_gap_label.text = ""


func _tower_row(cells: Array, bar: Color, you: bool) -> PanelContainer:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _panel_style(COL_ACCENT if you else COL_ROW, 8, Vector4(10, 1, 14, 2)))
	row.custom_minimum_size.x = 290
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	row.add_child(line)
	var rank := _label(26, COL_ON_ACCENT if you else COL_TEXT)
	rank.add_theme_constant_override("outline_size", 0)
	rank.text = cells[0]
	rank.custom_minimum_size.x = 30
	rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.add_child(rank)
	var swatch := ColorRect.new()
	swatch.color = bar
	swatch.custom_minimum_size = Vector2(5, 26)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(swatch)
	var name_label := _label(26, COL_ON_ACCENT if you else COL_TEXT)
	name_label.add_theme_constant_override("outline_size", 0)
	name_label.text = cells[2]
	name_label.clip_text = true
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(name_label)
	return row


## The LED countdown: "3", "2", "1", then "GO".
func show_countdown(text: String) -> void:
	var go := text == "GO"
	_led.text = text
	_led.color = COL_ACCENT if go else COL_LED
	var board := _led.board_size()
	_led.size = board
	_led.pivot_offset = board * 0.5
	# Above the middle, so it never covers the car waiting on the grid.
	_led.position = Vector2((_root.size.x - board.x) * 0.5, maxf(MARGIN, _root.size.y * 0.27 - board.y * 0.5))
	_led.reveal = 0.0
	_led.scale = Vector2.ONE * 1.25
	_led.modulate.a = 1.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_led, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_led, "reveal", 1.0, 0.14)
	tween.chain().tween_interval(0.55 if go else 0.62)
	if go:
		tween.chain().tween_property(_led, "scale", Vector2.ONE * 1.6, 0.25)
		tween.tween_property(_led, "modulate:a", 0.0, 0.25)
	else:
		tween.chain().tween_property(_led, "modulate:a", 0.0, 0.14)


func show_intro(on: bool) -> void:
	if _intro_tween:
		_intro_tween.kill()
	_intro_tween = create_tween()
	if on:
		_intro.visible = true
		_intro.modulate.a = 0.0
		_intro_tween.tween_property(_intro, "modulate:a", 1.0, 0.35)
	else:
		_intro_tween.tween_property(_intro, "modulate:a", 0.0, 0.3)
		_intro_tween.tween_callback(func() -> void: _intro.visible = false)


## The big one in the middle of the screen: FINISH, TIME'S UP, SESSION CLOSED.
func show_banner(text: String, color := COL_TEXT, seconds := 0.9) -> void:
	if _banner_tween:
		_banner_tween.kill()
	_banner.text = text
	# Shrink long messages so they fit.
	var fit := _root.size.x * 1.55 / maxf(1.0, float(text.length()))
	_banner.add_theme_font_size_override("font_size", int(clampf(fit, 44.0, 110.0)))
	_banner.add_theme_color_override("font_color", color)
	_banner.modulate.a = 1.0
	_banner.pivot_offset = _banner.size * 0.5
	_banner.scale = Vector2.ONE * 1.25
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "scale", Vector2.ONE, 0.15)
	_banner_tween.tween_interval(seconds)
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, 0.25)


## A small pill near the top for things that happen while driving (boost, bug, lap time).
## It pops in, holds, then drifts up and fades, without covering the road ahead.
func show_toast(text: String, color := COL_ACCENT, seconds := 0.8) -> void:
	if _toast_tween:
		_toast_tween.kill()
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", color.lightened(0.45))
	_toast_style.border_color = color
	_toast.reset_size()
	var rest_y := _root.size.y * 0.17
	# Centre it by hand: a pill that just shrank keeps its old left edge otherwise.
	_toast.position = Vector2((_root.size.x - _toast.size.x) * 0.5, rest_y + 14.0)
	_toast.pivot_offset = _toast.size * 0.5
	_toast.scale = Vector2.ONE * 0.6
	_toast.modulate.a = 0.0

	_toast_tween = create_tween()
	_toast_tween.set_parallel(true)
	_toast_tween.tween_property(_toast, "modulate:a", 1.0, 0.10)
	_toast_tween.tween_property(_toast, "scale", Vector2.ONE, 0.26).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_toast_tween.tween_property(_toast, "position:y", rest_y, 0.26).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_toast_tween.chain().tween_interval(seconds)
	_toast_tween.chain().tween_property(_toast, "position:y", rest_y - 30.0, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.35)


## The small centred panel: start, practice, connection trouble. `rows` and `highlight` are
## accepted for compatibility and ignored; standings go through show_results().
func show_panel(title: String, subtitle: String, button_text: String, note := "", _rows: Array = [], _highlight := -1) -> void:
	_close(_results)
	_panel_open = true
	_panel_title.text = title
	_panel_subtitle.text = subtitle
	_panel_subtitle.visible = not subtitle.is_empty()
	_panel_note.text = note
	_panel_note.visible = not note.is_empty()
	_panel_button.text = button_text
	_panel_button.visible = not button_text.is_empty()
	_open(_panel)


## The results table. Each row is [position, name, best lap, total, colour]; `highlight` is
## the player's own row. When the table first opens with `count_to_ms` given, the big time
## counts up to it.
func show_results(title: String, subtitle: String, button_text: String, note: String, rows: Array, highlight: int,
		session_name: String, count_to_ms := -1) -> void:
	_close(_panel)
	var opening := not _results.visible or _results.modulate.a < 0.5
	_panel_open = true
	_results_session.text = session_name
	if _count_tween:
		_count_tween.kill()
	_results_time.text = title
	if opening and count_to_ms > 0:
		_count_tween = create_tween()
		_count_tween.tween_method(func(ms: float) -> void: _results_time.text = format_time(int(ms)), 0.0, float(count_to_ms), 0.8) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_count_tween.tween_callback(func() -> void: _results_time.text = title)
	_results_subtitle.text = subtitle
	_results_subtitle.visible = not subtitle.is_empty()
	_results_note.text = note
	_results_note.visible = not note.is_empty()
	for child in _results_rows.get_children():
		child.queue_free()
	for i in rows.size():
		var cells: Array = rows[i]
		var own := i == highlight
		var bar := Color(str(cells[4])) if cells.size() > 4 else COL_ACCENT
		var row := _table_row([cells[0], "", cells[1], cells[2], cells[3]], COL_ACCENT if own else COL_ROW, COL_ON_ACCENT if own else COL_TEXT, 26, bar)
		_results_rows.add_child(row)
		if opening:
			# Rows come in one after another, top first.
			row.modulate.a = 0.0
			var tween := row.create_tween()
			tween.tween_interval(0.18 + i * 0.07)
			tween.tween_property(row, "modulate:a", 1.0, 0.2)
	_results_rows.visible = not rows.is_empty()
	_results_button.text = button_text
	_results_button.visible = not button_text.is_empty()
	_open(_results)


func hide_panel() -> void:
	_panel_open = false
	_close(_panel)
	_close(_results)


func is_panel_visible() -> bool:
	return _panel_open


## Pops a panel in: fades up and springs from a little smaller.
func _open(control: Control) -> void:
	if control.has_meta("tween"):
		(control.get_meta("tween") as Tween).kill()
	if not control.visible or control.modulate.a < 0.05:
		control.modulate.a = 0.0
		control.scale = Vector2.ONE * 0.9
	control.visible = true
	var tween := create_tween().set_parallel(true)
	tween.tween_property(control, "modulate:a", 1.0, 0.2)
	tween.tween_property(control, "scale", Vector2.ONE, 0.34).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	control.set_meta("tween", tween)


## Fades a panel out and shrinks it a touch, then hides it.
func _close(control: Control) -> void:
	if not control.visible:
		return
	if control.has_meta("tween"):
		(control.get_meta("tween") as Tween).kill()
	var tween := create_tween().set_parallel(true)
	tween.tween_property(control, "modulate:a", 0.0, 0.16)
	tween.tween_property(control, "scale", Vector2.ONE * 0.95, 0.16)
	tween.chain().tween_callback(func() -> void: control.visible = false)
	control.set_meta("tween", tween)


static func format_time(ms: int) -> String:
	var centis := int(round(ms / 10.0))
	return "%d:%02d.%02d" % [centis / 6000, (centis % 6000) / 100, centis % 100]


# --- touch input ----------------------------------------------------------------------------------
# Left thumb: the steering stick, anywhere on the left half of the screen, measured from the
# stick's centre. Right thumb: the accelerate and reverse buttons. A finger can slide from one
# button to the other without lifting.

func _input(event: InputEvent) -> void:
	if _intro.visible and _intro.modulate.a > 0.5:
		var tapped := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
			or (event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo)
		if tapped:
			skip_requested.emit()
			return
	if not sticks_enabled or spectating:
		return
	if event is InputEventScreenTouch:
		var touch: InputEventScreenTouch = event
		if touch.pressed:
			if _sound_button.get_global_rect().has_point(touch.position):
				return
			var pedal := _pedal_at(touch.position)
			if not pedal.is_empty():
				_pedal_touches[touch.index] = pedal
				_update_pedals()
			elif touch.position.x < _root.size.x * 0.5 and _steer_touch == -1:
				_steer_touch = touch.index
				_update_steer(touch.position)
		elif touch.index == _steer_touch:
			_steer_touch = -1
			steer = 0.0
			_steer_stick.value = 0.0
		elif _pedal_touches.has(touch.index):
			_pedal_touches.erase(touch.index)
			_update_pedals()
	elif event is InputEventScreenDrag:
		var drag: InputEventScreenDrag = event
		if drag.index == _steer_touch:
			_update_steer(drag.position)
		elif _pedal_touches.has(drag.index):
			_pedal_touches[drag.index] = _pedal_at(drag.position)
			_update_pedals()


func _update_steer(at: Vector2) -> void:
	steer = clampf((at.x - _steer_stick.center().x) / TouchStick.TRAVEL, -1.0, 1.0)
	_steer_stick.value = steer


## Which pedal a point is on. The hit area is a good deal larger than the drawing, because
## nobody looks at their thumbs while driving.
func _pedal_at(at: Vector2) -> String:
	var gas := at.distance_to(_gas_button.center()) / (_gas_button.radius * 1.35)
	var back := at.distance_to(_reverse_button.center()) / (_reverse_button.radius * 1.35)
	if gas > 1.0 and back > 1.0:
		return ""
	return "gas" if gas <= back else "reverse"


func _update_pedals() -> void:
	var held := _pedal_touches.values()
	var gas := held.has("gas")
	var back := held.has("reverse")
	# Both at once: the brake wins.
	throttle = -1.0 if back else (1.0 if gas else 0.0)
	_gas_button.pressed = gas
	_reverse_button.pressed = back


## Lets the keyboard (or the autopilot) show on the drawn controls too.
func mirror_input(steer_value: float, throttle_value: float) -> void:
	if _steer_touch == -1:
		_steer_stick.value = steer_value
	if _pedal_touches.is_empty():
		_gas_button.pressed = throttle_value > 0.1
		_reverse_button.pressed = throttle_value < -0.1


func _release_all() -> void:
	_steer_touch = -1
	_pedal_touches.clear()
	steer = 0.0
	throttle = 0.0
	if _steer_stick:
		_steer_stick.value = 0.0
		_gas_button.pressed = false
		_reverse_button.pressed = false


func _label(font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.06, 0.02, 0.1))
	label.add_theme_constant_override("outline_size", 10)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
