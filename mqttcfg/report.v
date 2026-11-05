module mqttcfg

// Rules for the optional planner report: this node periodically posts a summary of the repeaters and rooms it has heard to a planner service
// (for example xerokuhl.com's). Shared by the daemon and the web UI, which are separate programs. Settings live in the mqtt_settings table
// under the keys below.

pub const report_key_enabled = 'report_enabled'
pub const report_key_url = 'report_url'
pub const report_key_token = 'report_token'
pub const report_key_minutes = 'report_minutes'
pub const report_key_public = 'report_public_position'
pub const report_key_lat = 'report_lat'
pub const report_key_lon = 'report_lon'

pub const report_default_minutes = 15
pub const report_min_minutes = 5
pub const report_max_minutes = 120
pub const report_min_token = 24

// valid_report_url returns '' when the address can be posted to, else the reason. Only https, and only characters that cannot change meaning
// when the address is handed to curl: the daemon puts it inside single quotes on a command line.
pub fn valid_report_url(raw string) string {
	u := raw.trim_space()
	if !u.starts_with('https://') {
		return 'the address must start with https://'
	}
	rest := u['https://'.len..]
	if rest.len == 0 || rest.len > 300 || rest.starts_with('/') {
		return 'the address needs a host name after https://'
	}
	for c in rest {
		ok := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c in [
			`.`,
			`-`,
			`_`,
			`:`,
			`/`,
			`~`,
			`%`,
			`+`,
		]
		if !ok {
			return 'the address has a character that is not allowed (letters, digits and . - _ : / ~ % + only)'
		}
	}
	return ''
}

// valid_report_token: long enough to be a secret, and plain printable characters (it travels in an HTTP header).
pub fn valid_report_token(t string) bool {
	if t.len < report_min_token || t.len > 200 {
		return false
	}
	for c in t {
		if c < `!` || c > `~` || c == `'` || c == `"` || c == `\\` {
			return false
		}
	}
	return true
}

// report_minutes reads the interval setting, falling back to the default and keeping it inside the allowed range.
pub fn report_minutes(s string) int {
	n := s.trim_space().int()
	if n <= 0 {
		return report_default_minutes
	}
	return if n < report_min_minutes {
		report_min_minutes
	} else if n > report_max_minutes {
		report_max_minutes
	} else {
		n
	}
}

// parse_position reads the node's own position, both fields or neither. -> latitude, longitude, whether one was given, and the reason if it is wrong.
pub fn parse_position(lat string, lon string) (f64, f64, bool, string) {
	a := lat.trim_space()
	b := lon.trim_space()
	if a == '' && b == '' {
		return 0, 0, false, ''
	}
	if a == '' || b == '' {
		return 0, 0, false, 'give both latitude and longitude, or neither'
	}
	la := a.f64()
	lo := b.f64()
	if (la == 0 && a !in ['0', '0.0']) || (lo == 0 && b !in ['0', '0.0']) {
		return 0, 0, false, 'latitude and longitude must be numbers'
	}
	if la < -90 || la > 90 || lo < -180 || lo > 180 {
		return 0, 0, false, 'latitude is -90 to 90 and longitude -180 to 180'
	}
	return la, lo, true, ''
}
