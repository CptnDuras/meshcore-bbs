module main

import json

// A fake publisher pipe so lifecycle logic is testable without a process.
@[heap]
struct FakePipe {
mut:
	lines   []string
	up      bool = true
	stopped bool
	full    bool
}

fn (mut f FakePipe) alive() bool {
	return f.up
}

fn (mut f FakePipe) write_line(s string) bool {
	if f.full {
		return false
	}
	f.lines << s
	return true
}

fn (mut f FakePipe) stop() {
	f.stopped = true
	f.up = false
}

@[heap]
struct Counter {
mut:
	n int
}

struct Harness {
mut:
	rt     MqttRuntime
	pipes  []&FakePipe
	starts int
}

fn new_harness(mut store Store) &Harness {
	mut h := &Harness{
		rt: MqttRuntime{
			ident: MqttIdentity{
				origin:    'MESHBBS'
				origin_id: 'AB'.repeat(32)
				model:     'Heltec V3'
				fw:        '1.17.1'
			}
		}
	}
	h.rt.factory = fn [mut h] () !MqttPipe {
		h.starts++
		p := &FakePipe{}
		h.pipes << p
		return p
	}
	return h
}

fn enabled_store() Store {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	store.mqtt_set('enabled', '1') or { panic(err) }
	store.mqtt_set('iata', 'BYG') or { panic(err) }
	store.add_mqtt_broker(MqttBroker{
		name:      'local'
		host:      '127.0.0.1'
		port:      1883
		transport: 'tcp'
		auth:      'none'
		enabled:   true
	}) or { panic(err) }
	return store
}

fn test_disabled_never_starts() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	mut h := new_harness(mut store)
	h.rt.tick(1000, mut store)
	assert h.starts == 0
	assert (store.mqtt_get('state') or { '' }).starts_with('off')
}

fn test_enabled_starts_once_and_sends_config_once() {
	mut store := enabled_store()
	mut h := new_harness(mut store)
	h.rt.tick(1000, mut store)
	h.rt.tick(1001, mut store)
	h.rt.tick(1002, mut store)
	assert h.starts == 1
	assert h.pipes[0].lines.len == 1
	c := json.decode(MqttCfgCmd, h.pipes[0].lines[0]) or { panic(err) }
	assert c.cmd == 'config'
	assert c.iata == 'BYG'
	assert c.origin == 'MESHBBS'
	assert c.origin_id == 'AB'.repeat(32)
	assert c.brokers.len == 1
	assert c.brokers[0].host == '127.0.0.1'
	assert (store.mqtt_get('state') or { '' }).starts_with('running')
}

fn test_config_change_resends() {
	mut store := enabled_store()
	mut h := new_harness(mut store)
	h.rt.tick(1000, mut store)
	store.mqtt_set('iata', 'SHR') or { panic(err) }
	h.rt.tick(1001, mut store)
	assert h.starts == 1
	assert h.pipes[0].lines.len == 2
	c := json.decode(MqttCfgCmd, h.pipes[0].lines[1]) or { panic(err) }
	assert c.iata == 'SHR'
}

fn test_disable_sends_stop_and_stops_pipe() {
	mut store := enabled_store()
	mut h := new_harness(mut store)
	h.rt.tick(1000, mut store)
	store.mqtt_set('enabled', '0') or { panic(err) }
	h.rt.tick(1001, mut store)
	assert h.pipes[0].stopped
	assert h.pipes[0].lines.last().contains('"stop"')
	// and it stays off
	h.rt.tick(1002, mut store)
	assert h.starts == 1
}

fn test_crashed_pipe_restarts_after_backoff_with_config() {
	mut store := enabled_store()
	mut h := new_harness(mut store)
	h.rt.tick(1000, mut store)
	h.pipes[0].up = false // publisher died
	h.rt.tick(1001, mut store)
	assert h.starts == 1 // backing off, not a tight restart loop
	assert (store.mqtt_get('state') or { '' }).contains('restart')
	h.rt.tick(1000 + mqtt_restart_backoff + 5, mut store)
	assert h.starts == 2
	assert h.pipes[1].lines.len == 1 // config re-sent to the new process
}

fn test_factory_failure_is_survivable() {
	mut store := enabled_store()
	mut h := new_harness(mut store)
	h.rt.factory = fn () !MqttPipe {
		return error('python not found')
	}
	h.rt.tick(1000, mut store)
	assert (store.mqtt_get('state') or { '' }).contains('python not found')
	assert h.starts == 0
}

fn test_invalid_iata_waits_with_reason() {
	mut store := enabled_store()
	store.mqtt_set('iata', 'nope') or { panic(err) }
	mut h := new_harness(mut store)
	h.rt.tick(1000, mut store)
	assert h.starts == 0
	assert (store.mqtt_get('state') or { '' }).contains('IATA')
}

fn test_no_brokers_waits_with_reason() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	store.mqtt_set('enabled', '1') or { panic(err) }
	store.mqtt_set('iata', 'BYG') or { panic(err) }
	mut h := new_harness(mut store)
	h.rt.tick(1000, mut store)
	assert h.starts == 0
	assert (store.mqtt_get('state') or { '' }).contains('broker')
}

fn test_unknown_identity_waits() {
	mut store := enabled_store()
	mut h := new_harness(mut store)
	h.rt.ident = MqttIdentity{}
	h.rt.tick(1000, mut store)
	assert h.starts == 0
	assert (store.mqtt_get('state') or { '' }).contains('radio')
}

fn test_on_packet_publishes_when_running() {
	mut store := enabled_store()
	mut h := new_harness(mut store)
	h.rt.tick(1000, mut store)
	raw := [u8(0x09), 0x02, 0xAA, 0xBB, 0x01, 0x02, 0x03, 0x04, 0x05]
	h.rt.on_packet(1760000000, 5.5, -97.0, raw)
	assert h.pipes[0].lines.len == 2
	cmd := json.decode(map[string]string, h.pipes[0].lines[1]) or { panic(err) }
	assert cmd['cmd'] == 'packet'
	inner := json.decode(map[string]string, cmd['payload']) or { panic(err) }
	assert inner['hash'] == '23ADB40BCDA9A241'
	assert inner['origin'] == 'MESHBBS'
}

fn test_on_packet_noop_when_off_or_garbage() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	mut h := new_harness(mut store)
	h.rt.on_packet(1, 0, 0, [u8(1), 2, 3]) // not running: must not crash
	mut store2 := enabled_store()
	mut h2 := new_harness(mut store2)
	h2.rt.tick(1000, mut store2)
	h2.rt.on_packet(1, 0, 0, [u8(1)]) // garbage
	assert h2.pipes[0].lines.len == 1 // only the config
}

fn test_full_pipe_drops_and_counts() {
	mut store := enabled_store()
	mut h := new_harness(mut store)
	h.rt.tick(1000, mut store)
	h.pipes[0].full = true
	raw := [u8(0x09), 0x02, 0xAA, 0xBB, 0x01, 0x02, 0x03, 0x04, 0x05]
	h.rt.on_packet(1, 0, 0, raw)
	h.rt.on_packet(2, 0, 0, raw)
	assert h.rt.dropped == 2
}

fn test_needs_key() {
	mut cfg := MqttConfig{
		enabled: true
		iata:    'BYG'
	}
	assert !mqtt_needs_key(cfg)
	cfg.brokers << MqttBroker{
		auth: 'none'
	}
	assert !mqtt_needs_key(cfg)
	cfg.brokers << MqttBroker{
		auth: 'token'
	}
	assert mqtt_needs_key(cfg)
}

fn test_key_goes_in_config_line_only_when_needed() {
	mut store := enabled_store()
	store.add_mqtt_broker(MqttBroker{
		name:      'mm'
		host:      'mqtt.meshmapper.net'
		port:      443
		transport: 'wss'
		auth:      'token'
		audience:  'mqtt.meshmapper.net'
		enabled:   true
	}) or { panic(err) }
	mut h := new_harness(mut store)
	h.rt.key = 'cd'.repeat(64)
	h.rt.tick(1000, mut store)
	c := json.decode(MqttCfgCmd, h.pipes[0].lines[0]) or { panic(err) }
	assert c.key == 'cd'.repeat(64)
	// no token brokers -> the key is not sent at all
	mut store2 := enabled_store()
	mut h2 := new_harness(mut store2)
	h2.rt.key = 'cd'.repeat(64)
	h2.rt.tick(1000, mut store2)
	c2 := json.decode(MqttCfgCmd, h2.pipes[0].lines[0]) or { panic(err) }
	assert c2.key == ''
}

fn test_key_loaded_lazily_for_token_brokers() {
	mut store := enabled_store()
	store.add_mqtt_broker(MqttBroker{
		name:      'mm'
		host:      'mqtt.meshmapper.net'
		port:      443
		transport: 'wss'
		auth:      'token'
		audience:  'mqtt.meshmapper.net'
		enabled:   true
	}) or { panic(err) }
	mut h := new_harness(mut store)
	mut ctr := &Counter{}
	h.rt.key_loader = fn [mut ctr] () !string {
		ctr.n++
		return 'ef'.repeat(64)
	}
	h.rt.tick(1000, mut store)
	h.rt.tick(1001, mut store)
	assert ctr.n == 1
	c := json.decode(MqttCfgCmd, h.pipes[0].lines[0]) or { panic(err) }
	assert c.key == 'ef'.repeat(64)
	assert (store.mqtt_get('key') or { '' }) == 'ok'
	// the key itself must never be written to the database
	for k in ['key', 'state', 'rev', 'iata', 'enabled'] {
		assert !(store.mqtt_get(k) or { '' }).contains('efefef')
	}
}

fn test_key_not_requested_without_token_brokers() {
	mut store := enabled_store() // auth none only
	mut h := new_harness(mut store)
	mut ctr := &Counter{}
	h.rt.key_loader = fn [mut ctr] () !string {
		ctr.n++
		return 'ef'.repeat(64)
	}
	h.rt.tick(1000, mut store)
	assert ctr.n == 0
}

fn test_key_failure_retries_later_and_publisher_still_starts() {
	mut store := enabled_store()
	store.add_mqtt_broker(MqttBroker{
		name:      'mm'
		host:      'mqtt.meshmapper.net'
		port:      443
		transport: 'wss'
		auth:      'token'
		audience:  'x'
		enabled:   true
	}) or { panic(err) }
	mut h := new_harness(mut store)
	mut ctr := &Counter{}
	h.rt.key_loader = fn [mut ctr] () !string {
		ctr.n++
		if ctr.n == 1 {
			return error('private key export is disabled in this firmware')
		}
		return 'ab'.repeat(64)
	}
	h.rt.tick(1000, mut store)
	assert h.starts == 1 // non-token brokers still work
	assert (store.mqtt_get('key') or { '' }).contains('disabled')
	h.rt.tick(1100, mut store)
	assert ctr.n == 1 // not hammering the radio
	h.rt.tick(1000 + mqtt_key_retry + 1, mut store)
	assert ctr.n == 2
	// config re-sent now that the key is known
	last := json.decode(MqttCfgCmd, h.pipes[0].lines.last()) or { panic(err) }
	assert last.key == 'ab'.repeat(64)
}
