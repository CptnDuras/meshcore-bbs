module mqttcfg

// Pure configuration rules for the optional MQTT observer, shared by the
// daemon (bbs/) and the web UI (webui/), which are separate programs.

// Broker is the plain-data form of an upstream MQTT broker.
//   transport: tcp | tls (MQTT over TLS) | ws | wss (WebSocket [+TLS])
//   auth:      none | password | token (JWT signed with the node's key)
pub struct Broker {
pub mut:
	name      string
	enabled   bool
	host      string
	port      int
	transport string = 'tcp'
	path      string
	auth      string = 'none'
	username  string
	password  string
	audience  string
}

pub fn normalize_iata(s string) string {
	return s.trim_space().to_upper()
}

// valid_iata: exactly three ASCII letters.
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

// validate returns '' when the broker is usable, else the reason.
pub fn validate(b Broker) string {
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

// --- presets: values from the meshcoretomqtt preset files. Token auth is a
// JWT signed with the node's own key, so it needs a node that allows key export.

fn token_wss(name string, host string) Broker {
	return Broker{
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

pub fn preset_names() []string {
	return ['meshmapper', 'waev-a', 'waev-b', 'letsmesh-us', 'letsmesh-eu', 'local']
}

pub fn preset(name string) ?Broker {
	return match name {
		'meshmapper' { token_wss('meshmapper', 'mqtt.meshmapper.net') }
		'waev-a' { token_wss('waev-a', 'mqtt-a.waev.app') }
		'waev-b' { token_wss('waev-b', 'mqtt-b.waev.app') }
		'letsmesh-us' { token_wss('letsmesh-us', 'mqtt-us-v1.letsmesh.net') }
		'letsmesh-eu' { token_wss('letsmesh-eu', 'mqtt-eu-v1.letsmesh.net') }
		'local' {
			Broker{
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

// broker_from_form builds a validated Broker from web-form fields: a named
// preset if 'preset' is set, else the custom fields. Returns (broker, error).
pub fn broker_from_form(f map[string]string) (Broker, string) {
	pname := (f['preset'] or { '' }).trim_space()
	if pname.len > 0 {
		b := preset(pname) or { return Broker{}, 'unknown preset ${pname}' }
		return b, ''
	}
	port_s := (f['port'] or { '' }).trim_space()
	if port_s.len == 0 || !port_s.bytes().all(it >= `0` && it <= `9`) {
		return Broker{}, 'port must be a number'
	}
	b := Broker{
		name:      (f['name'] or { '' }).trim_space()
		enabled:   true
		host:      (f['host'] or { '' }).trim_space()
		port:      port_s.int()
		transport: (f['transport'] or { 'tcp' }).trim_space()
		path:      (f['path'] or { '' }).trim_space()
		auth:      (f['auth'] or { 'none' }).trim_space()
		username:  (f['username'] or { '' }).trim_space()
		password:  f['password'] or { '' }
		audience:  (f['audience'] or { '' }).trim_space()
	}
	err := validate(b)
	return b, err
}

// Column lists of the MQTT tables the daemon creates (V ORM, from bbs/models.v).
// The web UI reads/writes these tables with raw SQL; bbs/mqtt_store_test.v
// asserts the real schema matches, so drift is caught by a test.
pub const settings_columns = ['id', 'key', 'val']
pub const broker_columns = ['id', 'name', 'enabled', 'host', 'port', 'transport', 'path', 'auth',
	'username', 'password', 'audience', 'created']
pub const status_columns = ['id', 'broker_id', 'state', 'last_error', 'published', 'updated']
