module main

import crypto.sha256
import json
import time

// Optional MQTT observer: reports the packets this node hears to MQTT brokers
// (map services such as MeshMapper / Waev, or a local broker). Everything here
// is configured from the web UI and stored in the DB; the feature is OFF until
// enabled there.

// MqttConfig is the effective, normalized configuration the daemon acts on.
pub struct MqttConfig {
pub mut:
	enabled bool
	iata    string
	brokers []MqttBroker // enabled brokers only
}

// load_mqtt_config reads settings + brokers from the store.
pub fn load_mqtt_config(mut store Store) MqttConfig {
	mut cfg := MqttConfig{
		enabled: (store.mqtt_get('enabled') or { '0' }) == '1'
		iata:    normalize_iata(store.mqtt_get('iata') or { '' })
	}
	for b in store.list_mqtt_brokers() {
		if b.enabled {
			cfg.brokers << b
		}
	}
	return cfg
}

// normalize_iata upper-cases and trims a location code. Validation (3 letters)
// is mqtt_validate_iata's job; this never fails.
pub fn normalize_iata(s string) string {
	return s.trim_space().to_upper()
}

// --- packet parsing -------------------------------------------------------
// MeshCore over-the-air layout (src/Packet.cpp):
//   header(1) [transport codes(4) if route is TRANSPORT_*] path_len(1)
//   path(hash_count*hash_size) payload(rest)
// header: bits0-1 route, bits2-5 payload type, bits6-7 version.
// path_len: bits0-5 hop count, bits6-7 (hash size - 1); size 4 is reserved.

pub struct PacketInfo {
pub:
	route       string // 'D' direct, 'F' flood (what the repeater logs)
	packet_type int
	payload_len int
	raw_len     int
	hash        string // 8-byte packet hash, upper-case hex
}

const max_path_size = 64

// parse_packet decodes the header of a raw packet and computes its hash.
// Returns none for anything that does not parse - never publish garbage.
pub fn parse_packet(raw []u8) ?PacketInfo {
	if raw.len < 3 {
		return none
	}
	header := raw[0]
	route_type := int(header & 0x03)
	ptype := int((header >> 2) & 0x0F)
	mut i := 1
	if route_type == 0 || route_type == 3 { // transport codes present
		i += 4
	}
	if i >= raw.len {
		return none
	}
	path_len := raw[i]
	i++
	hash_count := int(path_len & 63)
	hash_size := int(path_len >> 6) + 1
	if hash_size == 4 || hash_count * hash_size > max_path_size {
		return none
	}
	i += hash_count * hash_size
	if i >= raw.len { // need at least one payload byte
		return none
	}
	payload := raw[i..]
	mut msg := [u8(ptype)]
	if ptype == 9 { // TRACE hashes in path_len too (it can revisit a node)
		msg << path_len
	}
	msg << payload
	digest := sha256.sum256(msg)
	return PacketInfo{
		route:       if route_type == 2 || route_type == 3 { 'D' } else { 'F' }
		packet_type: ptype
		payload_len: payload.len
		raw_len:     raw.len
		hash:        digest[..8].hex().to_upper()
	}
}

// --- topics / validation --------------------------------------------------

pub fn observer_topic(iata string, pubkey string, kind string) string {
	return 'meshcore/${normalize_iata(iata)}/${pubkey.to_upper()}/${kind}'
}

pub fn valid_iata(s string) bool {
	t := s.trim_space()
	if t.len != 3 {
		return false
	}
	for c in t {
		if !((c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`)) {
			return false
		}
	}
	return true
}

fn valid_hostname(h string) bool {
	if h.len == 0 || h.len > 253 {
		return false
	}
	for c in h {
		ok := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
			|| c == `.` || c == `-` || c == `_` || c == `:`
		if !ok {
			return false
		}
	}
	return true
}

// mqtt_validate_broker returns '' when the broker is usable, else the reason.
pub fn mqtt_validate_broker(b MqttBroker) string {
	if b.name.trim_space().len == 0 || b.name.len > 40 {
		return 'name is required (max 40 chars)'
	}
	if !valid_hostname(b.host) {
		return 'host is missing or has invalid characters'
	}
	if b.port < 1 || b.port > 65535 {
		return 'port must be 1-65535'
	}
	if b.transport !in ['tcp', 'tls', 'ws', 'wss'] {
		return 'transport must be tcp, tls, ws or wss'
	}
	if b.auth !in ['none', 'password', 'token'] {
		return 'auth must be none, password or token'
	}
	if b.auth == 'password' && b.username.trim_space().len == 0 {
		return 'username is required for password auth'
	}
	if b.auth == 'token' && b.audience.trim_space().len == 0 {
		return 'audience is required for token auth'
	}
	return ''
}

// --- presets --------------------------------------------------------------
// Values come from the meshcoretomqtt preset files. Token auth = JWT signed
// with the node's own key, so these need a node that allows key export.

fn token_wss(name string, host string) MqttBroker {
	return MqttBroker{
		name:      name
		host:      host
		port:      443
		transport: 'wss'
		path:      '/'
		auth:      'token'
		audience:  host
		enabled:   true
	}
}

pub fn mqtt_preset_names() []string {
	return ['meshmapper', 'waev-a', 'waev-b', 'letsmesh-us', 'letsmesh-eu', 'local']
}

pub fn mqtt_preset(name string) ?MqttBroker {
	return match name {
		'meshmapper' { token_wss('meshmapper', 'mqtt.meshmapper.net') }
		'waev-a' { token_wss('waev-a', 'mqtt-a.waev.app') }
		'waev-b' { token_wss('waev-b', 'mqtt-b.waev.app') }
		'letsmesh-us' { token_wss('letsmesh-us', 'mqtt-us-v1.letsmesh.net') }
		'letsmesh-eu' { token_wss('letsmesh-eu', 'mqtt-eu-v1.letsmesh.net') }
		'local' {
			MqttBroker{
				name:      'local'
				host:      '127.0.0.1'
				port:      1883
				transport: 'tcp'
				auth:      'none'
				enabled:   true
			}
		}
		else { none }
	}
}

// --- payloads -------------------------------------------------------------

const client_version = 'meshbbs-mqtt/1'

// observer_packet_json builds the "packets" message in the same flat string
// format the repeater bridge publishes, so existing consumers accept it.
// SNR/RSSI are truncated to ints like the repeater's own log lines.
pub fn observer_packet_json(origin string, origin_id string, ts i64, snr f64, rssi f64, raw []u8) ?string {
	info := parse_packet(raw)?
	t := time.unix(ts)
	mut m := map[string]string{}
	m['origin'] = origin
	m['origin_id'] = origin_id
	m['timestamp'] = t.format_rfc3339()
	m['type'] = 'PACKET'
	m['direction'] = 'rx'
	m['time'] = '${t.hour:02}:${t.minute:02}:${t.second:02}'
	m['date'] = '${t.day}/${t.month}/${t.year}'
	m['len'] = info.raw_len.str()
	m['packet_type'] = info.packet_type.str()
	m['route'] = info.route
	m['payload_len'] = info.payload_len.str()
	m['raw'] = raw.hex().to_upper()
	m['SNR'] = int(snr).str()
	m['RSSI'] = int(rssi).str()
	m['hash'] = info.hash
	return json.encode(m)
}

pub fn observer_status_json(status string, origin string, origin_id string, ts i64, model string, fw string) string {
	mut m := map[string]string{}
	m['status'] = status
	m['timestamp'] = time.unix(ts).format_rfc3339()
	m['origin'] = origin
	m['origin_id'] = origin_id
	m['model'] = if model.len > 0 { model } else { 'unknown' }
	m['firmware_version'] = if fw.len > 0 { fw } else { 'unknown' }
	m['client_version'] = client_version
	return json.encode(m)
}
