module main

import json2
import os
import time

// Integration test against a real broker. Skipped unless pointed at one:
//
//   MQTT_IT_TCP=127.0.0.1:1883        MQTT_IT_WS=127.0.0.1:9001/
//   MQTT_IT_TLS=localhost:8883        MQTT_IT_WSS=localhost:9002/
//   MESHBBS_CA_FILE=/path/to/ca.pem   (for brokers with a private CA)
//
// Each endpoint is driven through the real daemon-facing pipe: connect, packet
// publish, counter report and clean stop. Watch the broker (mosquitto_sub -t
// 'meshcore/#' -v) to see the messages arrive.

const it_pub = '03A107BFF3CE10BE1D70DD18E74BC09967E4D6309BA50D5F1DDC8664125531B8'

fn it_endpoint(env string) ?(string, int, string) {
	v := os.getenv(env)
	if v.len == 0 {
		return none
	}
	slash := v.index('/') or { v.len }
	hp := v[..slash]
	path := if slash < v.len { v[slash..] } else { '/' }
	colon := hp.last_index(':') or { return none }
	return hp[..colon], hp[colon + 1..].int(), path
}

fn it_run(transport string, env string) {
	host, port, path := it_endpoint(env) or {
		eprintln('skipping ${env}: not set')
		return
	}
	mut pipe := new_native_pipe() or { panic(err) }
	cfg := json2.encode(MqttCfgCmd{
		cmd: 'config'
		iata: 'ITX'
		origin: 'IT'
		origin_id: it_pub
		model: 'it'
		fw: '1'
		brokers: [
			MqttCfgBroker{
				id: 9
				name: 'it'
				host: host
				port: port
				transport: transport
				path: path
				auth: 'none'
			},
		]
	},
		escape_unicode: true
	)
	assert pipe.write_line(cfg)
	mut connected := false
	mut last_err := ''
	deadline := time.ticks() + 15000
	for time.ticks() < deadline && !connected {
		for {
			line := pipe.read_status() or { break }
			m := json2.decode[MqttStatusMsg](line) or { continue }
			if m.id == 9 && m.t == 'status' {
				last_err = m.err_msg
				if m.state == 'connected' {
					connected = true
				}
			}
		}
		time.sleep(50 * time.millisecond)
	}
	assert connected, '${transport} ${host}:${port}: never connected (last error: ${last_err})'
	assert pipe.write_line(json2.encode({
		'cmd':     'packet'
		'payload': '{"it":"${transport}"}'
	},
		escape_unicode: true
	))
	mut counted := false
	deadline2 := time.ticks() + 6000
	for time.ticks() < deadline2 && !counted {
		for {
			line := pipe.read_status() or { break }
			m := json2.decode[MqttStatusMsg](line) or { continue }
			if m.id == 9 && m.state == 'connected' && m.published >= 1 {
				counted = true
			}
		}
		time.sleep(50 * time.millisecond)
	}
	assert counted, '${transport}: published counter never reached 1'
	pipe.write_line('{"cmd":"stop"}')
	pipe.stop()
	assert !pipe.alive()
}

fn test_it_tcp() {
	it_run('tcp', 'MQTT_IT_TCP')
}

fn test_it_ws() {
	it_run('ws', 'MQTT_IT_WS')
}

fn test_it_tls() {
	it_run('tls', 'MQTT_IT_TLS')
}

fn test_it_wss() {
	it_run('wss', 'MQTT_IT_WSS')
}
