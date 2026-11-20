extends Node
## WebSocket connection to the session server. Messages are JSON objects with a `t` field;
## the protocol is described in packages/shared/src/index.ts.

signal opened
signal closed
signal message_received(message: Dictionary)

var url := ""
var is_open := false
## Set when the server will never take us back (session gone, player removed); stops retries.
var give_up := false

var _socket: WebSocketPeer
var _retry_in := 0.0
var _attempt := 0


func connect_to(target_url: String) -> void:
	url = target_url
	give_up = false
	_open()


func send(message: Dictionary) -> void:
	if is_open:
		_socket.send_text(JSON.stringify(message))


func disconnect_from_server() -> void:
	give_up = true
	if _socket:
		_socket.close()


func _open() -> void:
	_socket = WebSocketPeer.new()
	# A browser stops running the game loop while its tab is in the background, but messages
	# keep arriving. Leave room for a few minutes of them instead of the 64 KB default.
	_socket.inbound_buffer_size = 1 << 20
	if _socket.connect_to_url(url) != OK:
		_socket = null
		_schedule_retry()


func _process(delta: float) -> void:
	if _socket == null:
		if url.is_empty() or give_up:
			return
		_retry_in -= delta
		if _retry_in <= 0.0:
			_open()
		return

	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not is_open:
				is_open = true
				_attempt = 0
				opened.emit()
			while _socket.get_available_packet_count() > 0:
				var parsed: Variant = JSON.parse_string(_socket.get_packet().get_string_from_utf8())
				if parsed is Dictionary:
					message_received.emit(parsed)
		WebSocketPeer.STATE_CLOSED:
			var code := _socket.get_close_code()
			_socket = null
			# 4001: this player connected from another tab. 4003: removed by the host.
			if code == 4001 or code == 4003:
				give_up = true
			if is_open:
				is_open = false
				closed.emit()
			if not give_up:
				_schedule_retry()


func _schedule_retry() -> void:
	_attempt += 1
	_retry_in = minf(8.0, 0.5 * pow(2.0, _attempt))
