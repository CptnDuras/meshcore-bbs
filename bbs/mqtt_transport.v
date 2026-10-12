module main

import crypto.rand
import encoding.base64
import net
import net.mbedtls
import os
import time

// Byte transports for the MQTT observer: plain TCP, TLS (certificate and host
// name are verified, always) and WebSocket over either. Reads never block for
// more than mqtt_poll so a single worker thread can interleave reading,
// writing, keepalive and shutdown without sharing the socket.

const mqtt_poll = 200 * time.millisecond
const mqtt_write_timeout = 10 * time.second
const mqtt_ws_handshake_secs = 10

const mqtt_ca_candidates = [
	'/etc/ssl/certs/ca-certificates.crt', // Debian, Ubuntu, Raspberry Pi OS, Alpine
	'/etc/pki/tls/certs/ca-bundle.crt', // Fedora, RHEL
	'/etc/ssl/ca-bundle.pem', // openSUSE
	'/usr/local/share/certs/ca-root-nss.crt', // FreeBSD (ca_root_nss)
	'/etc/ssl/cert.pem', // FreeBSD, macOS, Alpine
]

// MqttConn is one established, ready-to-use connection to a broker.
pub interface MqttConn {

	// read_some appends whatever MQTT bytes arrived; it returns (with nothing
	// appended) after a short timeout. An error means the connection is gone.
mut:
	read_some(mut out []u8) !
	write_all(data []u8) !
	close()
}

pub type MqttDialer = fn (b MqttCfgBroker) !MqttConn

// mqtt_ca_file locates the CA bundle used to verify broker certificates:
// $MESHBBS_CA_FILE, then <MESHBBS_HOME>/cacert.pem, then the usual system paths.
// There is deliberately no "skip verification" fallback.
pub fn mqtt_ca_file() !string {
	if f := os.getenv_opt('MESHBBS_CA_FILE') {
		if f.len > 0 {
			if !os.exists(f) {
				return error('MESHBBS_CA_FILE=${f} does not exist')
			}
			return f
		}
	}
	bundled := os.join_path(mqtt_home(), 'cacert.pem')
	if os.exists(bundled) {
		return bundled
	}
	for c in mqtt_ca_candidates {
		if os.exists(c) {
			return c
		}
	}
	return error('no CA certificate bundle found for TLS; install your OS ca-certificates package or set MESHBBS_CA_FILE')
}

fn mqtt_random_bytes(n int) ![]u8 {
	mut b := []u8{len: n}
	rand.read(mut b)!
	return b
}

fn mqtt_is_timeout(err IError) bool {
	if err.code() == net.err_timed_out_code || err.code() == -26624 { // -26624 = MBEDTLS_ERR_SSL_TIMEOUT
		return true
	}
	m := err.msg()
	return m.contains('did not receive any data') || m.contains('timed out')
}

// MqttRawConn is a TCP socket, optionally wrapped in TLS.
@[heap]
struct MqttRawConn {
mut:
	tcp &net.TcpConn = unsafe { nil }
	tls &mbedtls.SSLConn = unsafe { nil }
}

// read_chunk returns the number of bytes read, 0 on a poll timeout, and an
// error when the peer closed the connection or the socket failed.
fn (mut c MqttRawConn) read_chunk(mut buf []u8) !int {
	mut n := 0
	if c.tls != unsafe { nil } {
		n = c.tls.read(mut buf) or {
			if mqtt_is_timeout(err) {
				return 0
			}
			return err
		}
	} else {
		n = c.tcp.read(mut buf) or {
			if mqtt_is_timeout(err) {
				return 0
			}
			return err
		}
	}
	if n <= 0 {
		return error('connection closed by broker')
	}
	return n
}

fn (mut c MqttRawConn) write_all(data []u8) ! {
	mut off := 0
	for off < data.len {
		n := if c.tls != unsafe { nil } {
			c.tls.write(data[off..])!
		} else {
			c.tcp.write(data[off..])!
		}
		if n <= 0 {
			return error('write failed: connection closed')
		}
		off += n
	}
}

fn (mut c MqttRawConn) close_raw() {
	if c.tls != unsafe { nil } {
		c.tls.shutdown() or {}
	} else if c.tcp != unsafe { nil } {
		c.tcp.close() or {}
	}
}

// MqttStreamConn carries MQTT bytes directly over the raw socket.
@[heap]
struct MqttStreamConn {
mut:
	raw &MqttRawConn
	tmp []u8 = []u8{len: 4096}
}

pub fn (mut c MqttStreamConn) read_some(mut out []u8) ! {
	n := c.raw.read_chunk(mut c.tmp)!
	if n > 0 {
		out << c.tmp[..n]
	}
}

pub fn (mut c MqttStreamConn) write_all(data []u8) ! {
	c.raw.write_all(data)!
}

pub fn (mut c MqttStreamConn) close() {
	c.raw.close_raw()
}

// MqttWsConn carries MQTT bytes in WebSocket binary frames.
@[heap]
struct MqttWsConn {
mut:
	raw  &MqttRawConn
	tmp  []u8 = []u8{len: 4096}
	buf  []u8 // raw bytes not yet parsed into frames
	frag []u8 // message being reassembled from fragments
}

fn (mut c MqttWsConn) send_frame(opcode u8, payload []u8) ! {
	c.raw.write_all(ws_frame(opcode, payload, mqtt_random_bytes(4)!))!
}

pub fn (mut c MqttWsConn) read_some(mut out []u8) ! {
	n := c.raw.read_chunk(mut c.tmp)!
	if n > 0 {
		c.buf << c.tmp[..n]
	}
	for {
		f := ws_next_frame(mut c.buf)!
		if !f.complete {
			break
		}
		match f.opcode {
			ws_op_binary, ws_op_continuation {
				c.frag << f.payload
				if c.frag.len > mqtt_max_incoming {
					return error('websocket message too large')
				}
				if f.fin {
					out << c.frag
					c.frag.clear()
				}
			}
			ws_op_ping {
				c.send_frame(ws_op_pong, f.payload)!
			}
			ws_op_close {
				return error('websocket closed by broker')
			}
			else {}
		}
	}
}

pub fn (mut c MqttWsConn) write_all(data []u8) ! {
	c.send_frame(ws_op_binary, data)!
}

pub fn (mut c MqttWsConn) close() {
	c.send_frame(ws_op_close, [u8(0x03), 0xe8]) or {} // 1000 normal closure
	c.raw.close_raw()
}

// mqtt_ws_upgrade performs the HTTP upgrade on an established raw connection
// and returns any frame bytes the broker sent right behind its reply.
fn mqtt_ws_upgrade(mut raw MqttRawConn, b MqttCfgBroker) ![]u8 {
	key := base64.encode(mqtt_random_bytes(16)!)
	raw.write_all(ws_request(b.host, b.port, b.path, key, 'mqtt').bytes())!
	mut got := []u8{}
	mut tmp := []u8{len: 2048}
	deadline := time.now().unix() + mqtt_ws_handshake_secs
	for {
		if time.now().unix() > deadline {
			return error('websocket upgrade timed out')
		}
		n := raw.read_chunk(mut tmp)!
		if n > 0 {
			got << tmp[..n]
		}
		end := got.bytestr().index('\r\n\r\n') or { continue }
		ws_check_response(got[..end].bytestr(), key)!
		return got[end + 4..].clone()
	}
	return error('unreachable')
}

// mqtt_dial_real opens the transport a broker entry asks for.
pub fn mqtt_dial_real(b MqttCfgBroker) !MqttConn {
	tls := b.transport in ['tls', 'wss']
	ws := b.transport in ['ws', 'wss']
	ca := if tls { mqtt_ca_file()! } else { '' }
	mut t := net.dial_tcp('${b.host}:${b.port}')!
	t.set_read_timeout(mqtt_poll)
	t.set_write_timeout(mqtt_write_timeout)
	mut raw := &MqttRawConn{
		tcp: t
	}
	if tls {
		mut c := mbedtls.new_ssl_conn(
			verify: ca
			validate: true
			read_timeout: mqtt_poll
		) or {
			t.close() or {}
			return err
		}
		c.connect(mut t, b.host) or {
			t.close() or {}
			return err
		}
		c.set_read_timeout(mqtt_poll)
		raw.tls = c
	}
	if ws {
		leftover := mqtt_ws_upgrade(mut raw, b) or {
			raw.close_raw()
			return err
		}
		return &MqttWsConn{
			raw: raw
			buf: leftover
		}
	}
	return &MqttStreamConn{
		raw: raw
	}
}
