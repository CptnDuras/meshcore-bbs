module main

import mqttcfg
import os

// MQTT observer settings live in the shared DB so the web UI (a separate
// process) can edit them and the daemon can pick them up. Default is OFF.

fn test_mqtt_defaults_off() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	assert store.mqtt_get('enabled') or { '0' } == '0'
	assert store.list_mqtt_brokers().len == 0
	cfg := load_mqtt_config(mut store)
	assert !cfg.enabled
	assert cfg.brokers.len == 0
}

fn test_mqtt_settings_roundtrip_and_rev() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	r0 := store.mqtt_rev()
	store.mqtt_set('iata', 'BYG') or { panic(err) }
	assert store.mqtt_get('iata') or { '' } == 'BYG'
	// overwrite keeps one row
	store.mqtt_set('iata', 'SHR') or { panic(err) }
	assert store.mqtt_get('iata') or { '' } == 'SHR'
	// every config change bumps the revision so the daemon hot-reloads
	assert store.mqtt_rev() > r0
}

fn test_mqtt_broker_crud() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	b := store.add_mqtt_broker(MqttBroker{
		name: 'local'
		host: '127.0.0.1'
		port: 1883
		transport: 'tcp'
		auth: 'none'
		enabled: true
	}) or { panic(err) }
	assert b.id > 0
	assert store.list_mqtt_brokers().len == 1
	r1 := store.mqtt_rev()
	store.set_mqtt_broker_enabled(b.id, false) or { panic(err) }
	got := store.get_mqtt_broker(b.id) or { panic('missing') }
	assert !got.enabled
	assert store.mqtt_rev() > r1
	mut upd := got
	upd.host = 'broker.example.org'
	upd.port = 8883
	store.update_mqtt_broker(upd) or { panic(err) }
	again := store.get_mqtt_broker(b.id) or { panic('missing') }
	assert again.host == 'broker.example.org'
	assert again.port == 8883
	store.delete_mqtt_broker(b.id) or { panic(err) }
	assert store.list_mqtt_brokers().len == 0
	if _ := store.get_mqtt_broker(b.id) {
		panic('broker should be deleted')
	}
}

fn test_mqtt_status_upsert() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	r := store.mqtt_rev()
	store.set_mqtt_status(7, 'connecting', '', 0) or { panic(err) }
	store.set_mqtt_status(7, 'connected', '', 12) or { panic(err) }
	st := store.list_mqtt_status()
	assert st.len == 1
	assert st[0].broker_id == 7
	assert st[0].state == 'connected'
	assert st[0].published == 12
	// status updates are telemetry, not config: they must NOT bump the revision
	assert store.mqtt_rev() == r
}

fn test_load_mqtt_config_only_enabled_brokers() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or { panic(err) }
	store.mqtt_set('enabled', '1') or { panic(err) }
	store.mqtt_set('iata', 'byg') or { panic(err) }
	store.add_mqtt_broker(MqttBroker{ name: 'a', host: 'h1', port: 1883, transport: 'tcp', auth: 'none', enabled: true }) or {
		panic(err)
	}
	store.add_mqtt_broker(MqttBroker{ name: 'b', host: 'h2', port: 443, transport: 'wss', auth: 'token', enabled: false }) or {
		panic(err)
	}
	cfg := load_mqtt_config(mut store)
	assert cfg.enabled
	assert cfg.iata == 'BYG' // normalized to upper case
	assert cfg.brokers.len == 1
	assert cfg.brokers[0].name == 'a'
}

// The web UI talks to these tables with raw SQL using the column lists in
// mqttcfg. If the ORM models change, this fails until both are updated.
fn table_cols(path string, table string) []string {
	// a throwaway on-disk db so we can inspect the real ORM-created schema
	mut store := new_store('sqlite:${path}') or { panic(err) }
	store.migrate() or { panic(err) }
	mut s := store as SqliteStore
	rows := s.db.exec('PRAGMA table_info(${table})') or { panic(err) }
	mut cols := []string{}
	for r in rows {
		cols << r.vals[1]
	}
	return cols
}

fn test_orm_schema_matches_webui_contract() {
	path := os.join_path(os.temp_dir(), 'mqtt_schema_${os.getpid()}.db')
	defer {
		os.rm(path) or {}
	}
	assert table_cols(path, 'mqtt_settings') == mqttcfg.settings_columns
	assert table_cols(path, 'mqtt_brokers') == mqttcfg.broker_columns
	assert table_cols(path, 'mqtt_status') == mqttcfg.status_columns
}
