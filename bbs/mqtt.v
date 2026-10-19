module main

import crypto.sha256
import json2
import mqttcfg
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

// --- topics / validation / presets: rules live in the shared mqttcfg module
// (also used by the web UI); these wrappers adapt the ORM struct.

pub fn observer_topic(iata string, pubkey string, kind string) string {
	return 'meshcore/${normalize_iata(iata)}/${pubkey.to_upper()}/${kind}'
}

pub fn normalize_iata(s string) string {
	return mqttcfg.normalize_iata(s)
}

pub fn valid_iata(s string) bool {
	return mqttcfg.valid_iata(s)
}

fn broker_to_cfg(b MqttBroker) mqttcfg.Broker {
	return mqttcfg.Broker{
		name:      b.name
		enabled:   b.enabled
		host:      b.host
		port:      b.port
		transport: b.transport
		path:      b.path
		auth:      b.auth
		username:  b.username
		password:  b.password
		audience:  b.audience
	}
}

fn broker_from_cfg(b mqttcfg.Broker) MqttBroker {
	return MqttBroker{
		name:      b.name
		enabled:   b.enabled
		host:      b.host
		port:      b.port
		transport: b.transport
		path:      b.path
		auth:      b.auth
		username:  b.username
		password:  b.password
		audience:  b.audience
	}
}

// mqtt_validate_broker returns '' when the broker is usable, else the reason.
pub fn mqtt_validate_broker(b MqttBroker) string {
	return mqttcfg.validate(broker_to_cfg(b))
}

pub fn mqtt_preset_names() []string {
	return mqttcfg.preset_names()
}

pub fn mqtt_preset(name string) ?MqttBroker {
	b := mqttcfg.preset(name)?
	return broker_from_cfg(b)
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
	return json2.encode(m, escape_unicode: true)
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
	return json2.encode(m, escape_unicode: true)
}
