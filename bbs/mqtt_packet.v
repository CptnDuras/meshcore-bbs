module main

// MQTT 3.1.1 wire format: only what a publish-only (QoS 0) observer needs.

pub const mqtt_pt_connack = u8(2)
pub const mqtt_pt_pingresp = u8(13)

pub const mqtt_pingreq = [u8(0xc0), 0x00]
pub const mqtt_disconnect = [u8(0xe0), 0x00]

const mqtt_max_incoming = 1 << 20

pub struct MqttConnectOpts {
pub:
	client_id    string
	has_login    bool
	username     string
	password     string
	keepalive    int
	will_topic   string
	will_payload string
	will_retain  bool
}

fn mqtt_put_str(mut out []u8, s string) {
	out << u8(s.len >> 8)
	out << u8(s.len & 0xff)
	out << s.bytes()
}

fn mqtt_put_len(mut out []u8, n int) {
	mut x := n
	for {
		mut d := u8(x % 128)
		x /= 128
		if x > 0 {
			d |= 0x80
		}
		out << d
		if x == 0 {
			break
		}
	}
}

// mqtt_connect_packet builds a clean-session CONNECT, with an optional will
// (QoS 0) and optional username/password.
pub fn mqtt_connect_packet(o MqttConnectOpts) []u8 {
	mut flags := u8(0x02) // clean session
	has_will := o.will_topic.len > 0
	if has_will {
		flags |= 0x04
		if o.will_retain {
			flags |= 0x20
		}
	}
	if o.has_login {
		flags |= 0xc0 // username + password
	}
	mut body := []u8{}
	mqtt_put_str(mut body, 'MQTT')
	body << u8(4) // protocol level 3.1.1
	body << flags
	body << u8(o.keepalive >> 8)
	body << u8(o.keepalive & 0xff)
	mqtt_put_str(mut body, o.client_id)
	if has_will {
		mqtt_put_str(mut body, o.will_topic)
		mqtt_put_str(mut body, o.will_payload)
	}
	if o.has_login {
		mqtt_put_str(mut body, o.username)
		mqtt_put_str(mut body, o.password)
	}
	mut out := [u8(0x10)]
	mqtt_put_len(mut out, body.len)
	out << body
	return out
}

// mqtt_publish_packet builds a QoS 0 PUBLISH.
pub fn mqtt_publish_packet(topic string, payload string, retain bool) []u8 {
	mut body := []u8{}
	mqtt_put_str(mut body, topic)
	body << payload.bytes()
	mut first := u8(0x30)
	if retain {
		first |= 0x01
	}
	mut out := [first]
	mqtt_put_len(mut out, body.len)
	out << body
	return out
}

pub struct MqttPacket {
pub:
	ptype u8 // 0 = no complete packet buffered yet
	flags u8
	body  []u8
}

// mqtt_next_packet removes and returns the first complete packet from buf. A
// zero ptype means more bytes are needed. Malformed input is an error.
pub fn mqtt_next_packet(mut buf []u8) !MqttPacket {
	if buf.len < 2 {
		return MqttPacket{}
	}
	mut mult := 1
	mut n := 0
	mut i := 1
	for {
		if i >= buf.len {
			return MqttPacket{}
		}
		if i > 4 {
			return error('malformed MQTT remaining length')
		}
		b := buf[i]
		n += int(b & 0x7f) * mult
		mult *= 128
		i++
		if b & 0x80 == 0 {
			break
		}
	}
	if n > mqtt_max_incoming {
		return error('MQTT packet too large (${n} bytes)')
	}
	if buf.len < i + n {
		return MqttPacket{}
	}
	p := MqttPacket{
		ptype: buf[0] >> 4
		flags: buf[0] & 0x0f
		body:  buf[i..i + n].clone()
	}
	buf.delete_many(0, i + n)
	return p
}

// mqtt_connack_text explains a CONNACK return code.
pub fn mqtt_connack_text(rc int) string {
	return match rc {
		1 { 'unacceptable protocol version' }
		2 { 'client identifier rejected' }
		3 { 'server unavailable' }
		4 { 'bad username or password' }
		5 { 'not authorized' }
		else { 'return code ${rc}' }
	}
}
