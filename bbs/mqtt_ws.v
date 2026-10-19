module main

import crypto.sha1
import encoding.base64

// Minimal RFC 6455 client codec for MQTT-over-WebSocket. V's stdlib client is
// not used: it can neither validate server certificates nor negotiate the
// "mqtt" subprotocol.

const ws_guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
const ws_max_message = 1 << 20

pub const ws_op_continuation = u8(0x0)
pub const ws_op_text = u8(0x1)
pub const ws_op_binary = u8(0x2)
pub const ws_op_close = u8(0x8)
pub const ws_op_ping = u8(0x9)
pub const ws_op_pong = u8(0xa)

// ws_accept_for is the Sec-WebSocket-Accept value a server must answer with.
pub fn ws_accept_for(key string) string {
	return base64.encode(sha1.sum((key + ws_guid).bytes()))
}

// ws_request builds the HTTP upgrade request.
pub fn ws_request(host string, port int, path string, key string, subprotocol string) string {
	p := if path.len == 0 { '/' } else { path }
	h := if port == 80 || port == 443 { host } else { '${host}:${port}' }
	return 'GET ${p} HTTP/1.1\r\nHost: ${h}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' + 'Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: ${subprotocol}\r\n\r\n'
}

// ws_check_response validates the server's upgrade reply (headers only).
pub fn ws_check_response(head string, key string) ! {
	lines := head.split('\r\n')
	if lines.len == 0 || !lines[0].starts_with('HTTP/1.1 101') {
		return error('websocket upgrade refused: ${if lines.len > 0 { lines[0] } else { '' }}')
	}
	want := ws_accept_for(key)
	for l in lines[1..] {
		i := l.index(':') or { continue }
		if l[..i].trim_space().to_lower() == 'sec-websocket-accept' {
			if l[i + 1..].trim_space() == want {
				return
			}
			return error('websocket upgrade: bad Sec-WebSocket-Accept')
		}
	}
	return error('websocket upgrade: missing Sec-WebSocket-Accept')
}

// ws_frame encodes one masked, final client frame. mask must be 4 bytes.
pub fn ws_frame(opcode u8, payload []u8, mask []u8) []u8 {
	mut out := [u8(0x80) | opcode]
	n := payload.len
	if n < 126 {
		out << (u8(0x80) | u8(n))
	} else if n < 65536 {
		out << u8(0x80 | 126)
		out << u8(n >> 8)
		out << u8(n & 0xff)
	} else {
		out << u8(0x80 | 127)
		for sh := 56; sh >= 0; sh -= 8 {
			out << u8((u64(n) >> u32(sh)) & 0xff)
		}
	}
	out << mask
	for i, b in payload {
		out << (b ^ mask[i % 4])
	}
	return out
}

pub struct WsFrame {
pub:
	complete bool
	fin      bool
	opcode   u8
	payload  []u8
}

// ws_next_frame removes and returns the first complete server frame from buf.
// complete == false means more bytes are needed. Server frames must be unmasked.
pub fn ws_next_frame(mut buf []u8) !WsFrame {
	if buf.len < 2 {
		return WsFrame{}
	}
	fin := buf[0] & 0x80 != 0
	opcode := buf[0] & 0x0f
	if buf[1] & 0x80 != 0 {
		return error('websocket server frame is masked')
	}
	mut n := u64(buf[1] & 0x7f)
	mut i := 2
	if n == 126 {
		if buf.len < 4 {
			return WsFrame{}
		}
		n = (u64(buf[2]) << 8) | u64(buf[3])
		i = 4
	} else if n == 127 {
		if buf.len < 10 {
			return WsFrame{}
		}
		n = 0
		for k in 2 .. 10 {
			n = (n << 8) | u64(buf[k])
		}
		i = 10
	}
	if n > u64(ws_max_message) {
		return error('websocket frame too large')
	}
	len := int(n)
	if buf.len < i + len {
		return WsFrame{}
	}
	f := WsFrame{
		complete: true
		fin:      fin
		opcode:   opcode
		payload:  buf[i..i + len].clone()
	}
	buf.delete_many(0, i + len)
	return f
}
