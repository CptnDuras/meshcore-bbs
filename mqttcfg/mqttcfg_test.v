module mqttcfg

fn good() Broker {
	return Broker{
		name:      'x'
		host:      'mqtt.example.org'
		port:      443
		transport: 'wss'
		auth:      'token'
		audience:  'mqtt.example.org'
	}
}

fn test_valid_iata() {
	assert valid_iata('BYG')
	assert valid_iata(' shr ')
	assert !valid_iata('')
	assert !valid_iata('BY')
	assert !valid_iata('BYGG')
	assert !valid_iata('B1G')
}

fn test_normalize_iata() {
	assert normalize_iata(' byg ') == 'BYG'
}

fn test_validate_ok() {
	assert validate(good()) == ''
}

fn test_validate_rejects() {
	mut b := good()
	b.name = ''
	assert validate(b).contains('name')
	b = good()
	b.host = ''
	assert validate(b).contains('host')
	b = good()
	b.host = 'bad host;rm -rf'
	assert validate(b).contains('host')
	b = good()
	b.port = 0
	assert validate(b).contains('port')
	b = good()
	b.port = 70000
	assert validate(b).contains('port')
	b = good()
	b.transport = 'pigeon'
	assert validate(b).contains('transport')
	b = good()
	b.auth = 'magic'
	assert validate(b).contains('auth')
	b = good()
	b.audience = ''
	assert validate(b).contains('audience')
	b = good()
	b.auth = 'password'
	b.username = ''
	assert validate(b).contains('username')
}

fn test_transports_accepted() {
	for t in ['tcp', 'tls', 'ws', 'wss'] {
		mut b := good()
		b.transport = t
		assert validate(b) == '', t
	}
}

fn test_presets() {
	names := preset_names()
	for want in ['meshmapper', 'waev-a', 'waev-b', 'letsmesh-us', 'letsmesh-eu', 'local'] {
		assert want in names
	}
	for n in names {
		b := preset(n) or { panic('preset ${n} missing') }
		assert validate(b) == '', 'preset ${n}: ${validate(b)}'
	}
	mm := preset('meshmapper') or { panic('x') }
	assert mm.host == 'mqtt.meshmapper.net'
	assert mm.port == 443
	assert mm.transport == 'wss'
	assert mm.auth == 'token'
	assert mm.audience == 'mqtt.meshmapper.net'
	if _ := preset('nope') {
		panic('unknown preset must be none')
	}
}

fn test_broker_from_form_custom_and_preset() {
	// preset fills everything; form values override nothing it didn't ask for
	b, err := broker_from_form({
		'preset': 'waev-a'
	})
	assert err == ''
	assert b.host == 'mqtt-a.waev.app'
	// custom
	c, err2 := broker_from_form({
		'preset':    ''
		'name':      'home'
		'host':      '10.0.0.5'
		'port':      '1883'
		'transport': 'tcp'
		'auth':      'password'
		'username':  'u'
		'password':  'p'
	})
	assert err2 == ''
	assert c.port == 1883 && c.username == 'u' && c.password == 'p'
	// invalid custom
	_, err3 := broker_from_form({
		'preset': ''
		'name':   'x'
		'host':   ''
		'port':   '1883'
	})
	assert err3.contains('host')
	// non-numeric port
	_, err4 := broker_from_form({
		'preset': ''
		'name':   'x'
		'host':   'h'
		'port':   'abc'
	})
	assert err4.contains('port')
}
