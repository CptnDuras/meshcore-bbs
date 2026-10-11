module main

// MQTT observer settings page: data layer. The web UI is a separate process
// from the radio daemon and only reads/writes the shared DB; the daemon notices
// the bumped `rev` setting and reloads. All SQL here is parameterized.

import db.sqlite
import mqttcfg
import time

struct MqttBrokerView {
	id           int
	name         string
	enabled      bool
	host         string
	port         int
	transport    string
	path         string
	auth         string
	username     string
	has_password bool
	audience     string
	state        string
	last_error   string
	published    i64
	updated      string
}

struct MqttPage {
	available bool // false when the daemon has not migrated the tables yet
	enabled   bool
	iata      string
	state     string // daemon's own description: off / running / waiting: ...
	key       string // private-key availability note (never the key)
	rev       string
	brokers   []MqttBrokerView
	presets   []string
}

fn mqtt_setting(mut db sqlite.DB, key string) string {
	rows := db.exec_param('SELECT val FROM mqtt_settings WHERE key=?', key) or { return '' }
	if rows.len == 0 {
		return ''
	}
	return rows[0].vals[0]
}

fn mqtt_put_setting(mut db sqlite.DB, key string, val string) {
	cur := db.exec_param2('UPDATE mqtt_settings SET val=? WHERE key=?', val, key) or { return }
	_ = cur
	rows := db.exec_param('SELECT COUNT(*) FROM mqtt_settings WHERE key=?', key) or { return }
	if rows.len > 0 && rows[0].vals[0] == '0' {
		db.exec_param2('INSERT INTO mqtt_settings (key, val) VALUES (?, ?)', key, val) or {}
	}
}

// mqtt_bump_rev tells the daemon the configuration changed.
fn mqtt_bump_rev(mut db sqlite.DB) {
	next := (mqtt_setting(mut db, 'rev').int() + 1).str()
	mqtt_put_setting(mut db, 'rev', next)
}

fn mqtt_load(mut db sqlite.DB) MqttPage {
	db.exec('SELECT 1 FROM mqtt_settings LIMIT 1') or {
		return MqttPage{
			presets: mqttcfg.preset_names()
		}
	}
	mut brokers := []MqttBrokerView{}
	rows := db.exec('SELECT b.id, b.name, b.enabled, b.host, b.port, b.transport, b.path, b.auth, b.username, b.password, b.audience, COALESCE(s.state,\'\'), COALESCE(s.last_error,\'\'), COALESCE(s.published,0), COALESCE(s.updated,0) FROM mqtt_brokers b LEFT JOIN mqtt_status s ON s.broker_id=b.id ORDER BY b.id') or {
		[]sqlite.Row{}
	}
	for r in rows {
		v := r.vals
		brokers << MqttBrokerView{
			id:           v[0].int()
			name:         v[1]
			enabled:      v[2] == '1'
			host:         v[3]
			port:         v[4].int()
			transport:    v[5]
			path:         v[6]
			auth:         v[7]
			username:     v[8]
			has_password: v[9].len > 0
			audience:     v[10]
			state:        v[11]
			last_error:   v[12]
			published:    v[13].i64()
			updated:      if v[14] == '0' { '' } else { fmt_ts(v[14]) }
		}
	}
	return MqttPage{
		available: true
		enabled:   mqtt_setting(mut db, 'enabled') == '1'
		iata:      mqtt_setting(mut db, 'iata')
		state:     mqtt_setting(mut db, 'state')
		key:       mqtt_setting(mut db, 'key')
		rev:       mqtt_setting(mut db, 'rev')
		brokers:   brokers
		presets:   mqttcfg.preset_names()
	}
}

// mqtt_save_settings stores the on/off switch and IATA code. Returns '' or an
// error message; on error nothing is changed.
fn mqtt_save_settings(mut db sqlite.DB, enabled bool, iata string) string {
	code := mqttcfg.normalize_iata(iata)
	if code.len > 0 && !mqttcfg.valid_iata(code) {
		return 'IATA code must be exactly 3 letters (e.g. BYG)'
	}
	if enabled && code.len == 0 {
		return 'set a 3-letter IATA code before enabling MQTT'
	}
	mqtt_put_setting(mut db, 'iata', code)
	mqtt_put_setting(mut db, 'enabled', if enabled { '1' } else { '0' })
	mqtt_bump_rev(mut db)
	return ''
}

fn mqtt_add_broker(mut db sqlite.DB, form map[string]string) string {
	b, err := mqttcfg.broker_from_form(form)
	if err.len > 0 {
		return err
	}
	db.exec_param_many('INSERT INTO mqtt_brokers (name, enabled, host, port, transport, path, auth, username, password, audience, created) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
		[b.name, '1', b.host, b.port.str(), b.transport, b.path, b.auth, b.username, b.password,
		b.audience, time.now().unix().str()]) or { return 'database error: ${err}' }
	mqtt_bump_rev(mut db)
	return ''
}

// mqtt_update_broker edits an existing broker. A blank password field keeps
// the stored one (the page never shows it).
fn mqtt_update_broker(mut db sqlite.DB, id int, form map[string]string) string {
	cur := db.exec_param('SELECT password FROM mqtt_brokers WHERE id=?', id.str()) or {
		return 'database error: ${err}'
	}
	if cur.len == 0 {
		return 'no such broker'
	}
	mut f := form.clone()
	f['preset'] = ''
	b0, ferr := mqttcfg.broker_from_form(f)
	if ferr.len > 0 {
		return ferr
	}
	mut b := b0
	if (form['password'] or { '' }).len == 0 {
		b.password = cur[0].vals[0]
	}
	verr := mqttcfg.validate(b)
	if verr.len > 0 {
		return verr
	}
	db.exec_param_many('UPDATE mqtt_brokers SET name=?, host=?, port=?, transport=?, path=?, auth=?, username=?, password=?, audience=? WHERE id=?',
		[b.name, b.host, b.port.str(), b.transport, b.path, b.auth, b.username, b.password,
		b.audience, id.str()]) or { return 'database error: ${err}' }
	mqtt_bump_rev(mut db)
	return ''
}

fn mqtt_toggle_broker(mut db sqlite.DB, id int, on bool) {
	db.exec_param2('UPDATE mqtt_brokers SET enabled=? WHERE id=?', if on { '1' } else { '0' }, id.str()) or {
		return
	}
	mqtt_bump_rev(mut db)
}

fn mqtt_delete_broker(mut db sqlite.DB, id int) {
	db.exec_param('DELETE FROM mqtt_brokers WHERE id=?', id.str()) or { return }
	db.exec_param('DELETE FROM mqtt_status WHERE broker_id=?', id.str()) or {}
	mqtt_bump_rev(mut db)
}

// --- tiny template helpers (veb templates can't do inline @if in attributes) ---

fn checked_attr(on bool) string {
	return if on { 'checked' } else { '' }
}

fn sel_attr(cur string, val string) string {
	return if cur == val { 'selected' } else { '' }
}

fn pw_hint(has bool) string {
	return if has { '(unchanged)' } else { '' }
}
