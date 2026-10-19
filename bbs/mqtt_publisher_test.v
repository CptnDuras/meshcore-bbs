module main

import json2
import sync
import time

// Publisher tests: real worker threads talking to an in-memory fake broker.

const t_pub = '03A107BFF3CE10BE1D70DD18E74BC09967E4D6309BA50D5F1DDC8664125531B8'
const t_prv = '3894eea49c580aef816935762be049559d6d1440dede12e6a125f1841fff8e6fa9d71862a3e5746b571be3d187b0041046f52ebd850c7cbd5fde8ee38473b649'
const t_t0 = i64(1760000000)

// ---- fakes ----

struct FakePkt {
	kind    string // connect | publish | pingreq | disconnect
	topic   string
	payload string
	retain  bool
}

struct FakeConnect {
mut:
	client_id string
	flags     u8
	keepalive int
	will_t    string
	will_p    string
	user      string
	pass      string
}

@[heap]
struct FakeConn {
mut:
	mu       &sync.Mutex = sync.new_mutex()
	parse    []u8
	inbox    []u8
	pkts     []FakePkt
	connect  FakeConnect
	closed   bool
	dropped  bool
	refuse   u8
	silent   bool
	hostport string
}

struct FakeCursor {
mut:
	off int
}

fn fake_str(b []u8, mut cur FakeCursor) string {
	n := (int(b[cur.off]) << 8) | int(b[cur.off + 1])
	s := b[cur.off + 2..cur.off + 2 + n].bytestr()
	cur.off += 2 + n
	return s
}

pub fn (mut f FakeConn) read_some(mut out []u8) ! {
	time.sleep(1 * time.millisecond)
	f.mu.lock()
	defer {
		f.mu.unlock()
	}
	if f.dropped {
		return error('fake connection dropped')
	}
	out << f.inbox
	f.inbox.clear()
}

pub fn (mut f FakeConn) write_all(data []u8) ! {
	f.mu.lock()
	defer {
		f.mu.unlock()
	}
	if f.dropped {
		return error('fake connection dropped')
	}
	f.parse << data
	for {
		p := mqtt_next_packet(mut f.parse)!
		if p.ptype == 0 {
			break
		}
		match p.ptype {
			1 {
				mut off := FakeCursor{
					off: 10
				}
				mut c := FakeConnect{
					flags:     p.body[7]
					keepalive: (int(p.body[8]) << 8) | int(p.body[9])
				}
				c.client_id = fake_str(p.body, mut off)
				if c.flags & 0x04 != 0 {
					c.will_t = fake_str(p.body, mut off)
					c.will_p = fake_str(p.body, mut off)
				}
				if c.flags & 0x80 != 0 {
					c.user = fake_str(p.body, mut off)
				}
				if c.flags & 0x40 != 0 {
					c.pass = fake_str(p.body, mut off)
				}
				f.connect = c
				f.pkts << FakePkt{
					kind: 'connect'
				}
				if !f.silent {
					f.inbox << [u8(0x20), 2, 0, f.refuse]
				}
			}
			3 {
				n := (int(p.body[0]) << 8) | int(p.body[1])
				f.pkts << FakePkt{
					kind:    'publish'
					topic:   p.body[2..2 + n].bytestr()
					payload: p.body[2 + n..].bytestr()
					retain:  p.flags & 1 != 0
				}
			}
			12 {
				f.pkts << FakePkt{
					kind: 'pingreq'
				}
				f.inbox << [u8(0xd0), 0]
			}
			14 {
				f.pkts << FakePkt{
					kind: 'disconnect'
				}
			}
			else {}
		}
	}
}

pub fn (mut f FakeConn) close() {
	f.mu.lock()
	f.closed = true
	f.mu.unlock()
}

fn (mut f FakeConn) packets() []FakePkt {
	f.mu.lock()
	defer {
		f.mu.unlock()
	}
	return f.pkts.clone()
}

fn (mut f FakeConn) publishes() []FakePkt {
	return f.packets().filter(it.kind == 'publish')
}

fn (mut f FakeConn) is_closed() bool {
	f.mu.lock()
	defer {
		f.mu.unlock()
	}
	return f.closed
}

fn (mut f FakeConn) said_goodbye() bool {
	return f.packets().any(it.kind == 'disconnect')
}

fn (mut f FakeConn) drop() {
	f.mu.lock()
	f.dropped = true
	f.mu.unlock()
}

fn (mut f FakeConn) conn_info() FakeConnect {
	f.mu.lock()
	defer {
		f.mu.unlock()
	}
	return f.connect
}

@[heap]
struct FakeNet {
mut:
	mu      &sync.Mutex = sync.new_mutex()
	conns   []&FakeConn
	refuse  map[string]u8 // "host:port" -> CONNACK return code
	unreach map[string]bool
}

fn (mut n FakeNet) dial(b MqttCfgBroker) !MqttConn {
	hp := '${b.host}:${b.port}'
	n.mu.lock()
	defer {
		n.mu.unlock()
	}
	if n.unreach[hp] {
		return error('dial ${hp}: connection refused')
	}
	c := &FakeConn{
		hostport: hp
		refuse:   n.refuse[hp]
	}
	n.conns << c
	return c
}

fn (mut n FakeNet) count() int {
	n.mu.lock()
	defer {
		n.mu.unlock()
	}
	return n.conns.len
}

// find returns the nth connection dialled to host:port.
fn (mut n FakeNet) find(hp string, nth int) &FakeConn {
	n.mu.lock()
	defer {
		n.mu.unlock()
	}
	mut seen := 0
	for c in n.conns {
		if c.hostport == hp {
			if seen == nth {
				return c
			}
			seen++
		}
	}
	panic('no connection #${nth} to ${hp}')
}

fn (mut n FakeNet) at(i int) &FakeConn {
	n.mu.lock()
	defer {
		n.mu.unlock()
	}
	return n.conns[i]
}

fn (n &FakeNet) dialer() MqttDialer {
	f := unsafe { n }
	return fn [f] (b MqttCfgBroker) !MqttConn {
		mut m := unsafe { f }
		return m.dial(b)
	}
}

@[heap]
struct FakeClock {
mut:
	mu &sync.Mutex = sync.new_mutex()
	t  i64
}

fn (mut c FakeClock) get() i64 {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	return c.t
}

fn (mut c FakeClock) add(secs i64) {
	c.mu.lock()
	c.t += secs
	c.mu.unlock()
}

fn (c &FakeClock) now_fn() fn () i64 {
	k := unsafe { c }
	return fn [k] () i64 {
		mut m := unsafe { k }
		return m.get()
	}
}

struct SinkEvent {
	kind      string
	id        int
	state     string
	err       string
	published i64
}

@[heap]
struct ListSink {
mut:
	mu     &sync.Mutex = sync.new_mutex()
	events []SinkEvent
}

pub fn (mut s ListSink) set(id int, state string, err string, published i64, ts i64) {
	s.mu.lock()
	s.events << SinkEvent{'set', id, state, err, published}
	s.mu.unlock()
}

pub fn (mut s ListSink) delete(id int) {
	s.mu.lock()
	s.events << SinkEvent{'delete', id, '', '', 0}
	s.mu.unlock()
}

// row is the latest status for a broker, like the database table.
fn (mut s ListSink) row(id int) ?SinkEvent {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	mut cur := ?SinkEvent(none)
	for e in s.events {
		if e.id != id {
			continue
		}
		cur = if e.kind == 'delete' { none } else { e }
	}
	return cur
}

fn (mut s ListSink) state(id int) string {
	r := s.row(id) or { return '' }
	return r.state
}

fn wait_until(ms int, cond fn () bool) bool {
	deadline := time.ticks() + ms
	for time.ticks() < deadline {
		if cond() {
			return true
		}
		time.sleep(5 * time.millisecond)
	}
	return cond()
}

struct Env {
mut:
	p    &MqttPublisher
	net  &FakeNet
	sink &ListSink
	clk  &FakeClock
}

fn new_env() Env {
	sink := &ListSink{}
	fnet := &FakeNet{}
	clk := &FakeClock{
		t: t_t0
	}
	dial := fnet.dialer()
	now := clk.now_fn()
	p := new_mqtt_publisher(sink, fn [sink, dial, now] (spec MqttBrokerSpec) MqttLink {
		return mqtt_start_worker(spec, dial, sink, now)
	}, now)
	return Env{
		p:    p
		net:  fnet
		sink: sink
		clk:  clk
	}
}

fn wss_broker() MqttCfgBroker {
	return MqttCfgBroker{
		id:        1
		name:      'meshmapper'
		host:      'mqtt.meshmapper.net'
		port:      443
		transport: 'wss'
		path:      '/'
		auth:      'token'
		audience:  'mqtt.meshmapper.net'
	}
}

fn tcp_broker() MqttCfgBroker {
	return MqttCfgBroker{
		id:        2
		name:      'local'
		host:      '127.0.0.1'
		port:      1883
		transport: 'tcp'
		auth:      'none'
	}
}

fn cfg_cmd(brokers []MqttCfgBroker, key string, iata string) MqttInCmd {
	return MqttInCmd{
		cmd:       'config'
		iata:      iata
		origin:    'MESHBBS'
		origin_id: t_pub
		model:     'Heltec V3'
		fw:        '1.17.1'
		key:       key
		brokers:   brokers
	}
}

fn status_of(payload string) string {
	m := json2.decode[map[string]string](payload) or { return '' }
	return m['status']
}

// ---- tests ----

fn test_token_broker_login_and_will() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([wss_broker()], t_prv, 'BYG'))
	assert wait_until(2000, fn [e] () bool {
		mut n := e.net
		return n.count() == 1
	})
	mut c := e.net.at(0)
	assert wait_until(2000, fn [mut c] () bool {
		return c.packets().len >= 1
	})
	ci := c.conn_info()
	assert ci.user == 'v1_${t_pub}'
	assert ci.pass.count('.') == 2
	assert ci.keepalive == 60
	assert ci.will_t == 'meshcore/BYG/${t_pub}/status'
	assert status_of(ci.will_p) == 'offline'
	assert ci.flags & 0x20 != 0 // will retain
	assert ci.client_id.len <= 23 && ci.client_id.starts_with('meshbbs_03a107bf_')
	assert e.sink.events[0].state == 'connecting'
}

fn test_tcp_none_broker_has_no_login() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([tcp_broker()], t_prv, 'BYG'))
	assert wait_until(2000, fn [e] () bool {
		mut n := e.net
		return n.count() == 1
	})
	mut c := e.net.at(0)
	assert wait_until(2000, fn [mut c] () bool {
		return c.packets().len >= 1
	})
	assert c.conn_info().flags & 0xc0 == 0
	assert c.hostport == '127.0.0.1:1883'
}

fn test_password_auth() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	mut b := tcp_broker()
	b = MqttCfgBroker{
		...b
		auth:     'password'
		username: 'u'
		password: 'pw'
	}
	e.p.handle(cfg_cmd([b], t_prv, 'BYG'))
	assert wait_until(2000, fn [e] () bool {
		mut n := e.net
		return n.count() == 1
	})
	mut c := e.net.at(0)
	assert wait_until(2000, fn [mut c] () bool {
		return c.packets().len >= 1
	})
	ci := c.conn_info()
	assert ci.user == 'u' && ci.pass == 'pw'
}

fn test_online_status_published_on_connect() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([tcp_broker()], t_prv, 'BYG'))
	assert wait_until(2000, fn [mut e] () bool {
		return e.sink.state(2) == 'connected'
	})
	mut c := e.net.at(0)
	pubs := c.publishes()
	assert pubs.len == 1
	assert pubs[0].topic == 'meshcore/BYG/${t_pub}/status'
	assert pubs[0].retain
	assert status_of(pubs[0].payload) == 'online'
	assert pubs[0].payload.contains('"origin":"MESHBBS"') && pubs[0].payload.contains('"model":"Heltec V3"')
	assert pubs[0].payload.contains('"firmware_version":"1.17.1"')
	assert pubs[0].payload.contains('"client_version":"meshbbs-mqtt/1"')
}

fn test_packets_only_go_to_connected_brokers() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.net.refuse['mqtt.meshmapper.net:443'] = 5 // meshmapper refuses us
	e.p.handle(cfg_cmd([wss_broker(), tcp_broker()], t_prv, 'BYG'))
	assert wait_until(3000, fn [mut e] () bool {
		return e.sink.state(2) == 'connected' && e.sink.state(1) == 'error'
	})
	e.p.handle(MqttInCmd{ cmd: 'packet', payload: '{"x":1}' })
	mut local := e.net.find('127.0.0.1:1883', 0)
	assert wait_until(2000, fn [mut local] () bool {
		return local.publishes().len == 2
	})
	assert local.publishes()[1].topic == 'meshcore/BYG/${t_pub}/packets'
	assert local.publishes()[1].payload == '{"x":1}'
	assert !local.publishes()[1].retain
	mut refused := e.net.find('mqtt.meshmapper.net:443', 0)
	assert refused.publishes().len == 0
	// the counter reaches the status table within a couple of seconds
	assert wait_until(4000, fn [mut e] () bool {
		r := e.sink.row(2) or { return false }
		return r.published == 1
	})
	r1 := e.sink.row(1)?
	assert r1.published == 0
	assert r1.err == 'connect refused: not authorized'
}

fn test_token_broker_without_key_errors_and_connects_nowhere() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([wss_broker()], '', 'BYG'))
	r := e.sink.row(1)?
	assert r.state == 'error' && r.err.contains('key')
	time.sleep(50 * time.millisecond)
	assert e.net.count() == 0
}

fn test_bad_key_is_reported_not_raised() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([wss_broker()], 'abcd', 'BYG'))
	assert e.sink.state(1) == 'error'
	assert e.net.count() == 0
}

fn test_reconfig_restarts_only_changed_brokers() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([wss_broker(), tcp_broker()], t_prv, 'BYG'))
	assert wait_until(3000, fn [mut e] () bool {
		return e.sink.state(1) == 'connected' && e.sink.state(2) == 'connected'
	})
	mut first_wss := e.net.find('mqtt.meshmapper.net:443', 0)
	mut first_tcp := e.net.find('127.0.0.1:1883', 0)
	changed := MqttCfgBroker{
		...tcp_broker()
		port: 1884
	}
	e.p.handle(cfg_cmd([wss_broker(), changed], t_prv, 'BYG'))
	assert wait_until(3000, fn [mut first_tcp] () bool {
		return first_tcp.is_closed()
	})
	assert !first_wss.is_closed()
	assert wait_until(3000, fn [e] () bool {
		mut n := e.net
		return n.count() == 3
	})
	assert e.net.find('127.0.0.1:1884', 0).hostport == '127.0.0.1:1884'
}

fn test_reconfig_removing_broker_says_offline_and_clears_status() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([wss_broker(), tcp_broker()], t_prv, 'BYG'))
	assert wait_until(3000, fn [mut e] () bool {
		return e.sink.state(1) == 'connected' && e.sink.state(2) == 'connected'
	})
	e.p.handle(cfg_cmd([wss_broker()], t_prv, 'BYG'))
	mut gone := e.net.find('127.0.0.1:1883', 0)
	assert gone.is_closed() && gone.said_goodbye()
	assert status_of(gone.publishes().last().payload) == 'offline'
	assert e.sink.row(2) == none
	assert e.sink.state(1) == 'connected'
}

fn test_iata_change_restarts_everything() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([tcp_broker()], t_prv, 'BYG'))
	assert wait_until(2000, fn [mut e] () bool {
		return e.sink.state(2) == 'connected'
	})
	e.p.handle(cfg_cmd([tcp_broker()], t_prv, 'SHR'))
	mut old := e.net.at(0)
	assert old.is_closed()
	assert wait_until(3000, fn [e] () bool {
		mut n := e.net
		return n.count() == 2
	})
	mut fresh := e.net.at(1)
	assert wait_until(2000, fn [mut fresh] () bool {
		return fresh.packets().len >= 1
	})
	assert fresh.conn_info().will_t == 'meshcore/SHR/${t_pub}/status'
}

fn test_stop_publishes_offline_and_disconnects() {
	mut e := new_env()
	e.p.handle(cfg_cmd([tcp_broker()], t_prv, 'BYG'))
	assert wait_until(2000, fn [mut e] () bool {
		return e.sink.state(2) == 'connected'
	})
	e.p.handle(MqttInCmd{ cmd: 'stop' })
	mut c := e.net.at(0)
	assert c.is_closed() && c.said_goodbye()
	assert status_of(c.publishes().last().payload) == 'offline'
	assert wait_until(1000, fn [mut e] () bool {
		return e.sink.state(2) == 'stopped'
	})
}

fn test_token_refreshed_before_expiry() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([wss_broker()], t_prv, 'BYG'))
	assert wait_until(2000, fn [mut e] () bool {
		return e.sink.state(1) == 'connected'
	})
	mut c := e.net.at(0)
	old := c.conn_info().pass
	e.clk.add(600)
	time.sleep(100 * time.millisecond)
	assert !c.is_closed() // still fresh
	e.clk.add(3000)
	assert wait_until(3000, fn [mut c] () bool {
		return c.is_closed()
	})
	assert wait_until(3000, fn [e] () bool {
		mut n := e.net
		return n.count() == 2
	})
	mut next := e.net.at(1)
	assert wait_until(2000, fn [mut next] () bool {
		return next.packets().len >= 1
	})
	assert next.conn_info().pass != old
}

fn test_reconnect_after_drop_uses_fresh_token() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(cfg_cmd([wss_broker()], t_prv, 'BYG'))
	assert wait_until(2000, fn [mut e] () bool {
		return e.sink.state(1) == 'connected'
	})
	mut c := e.net.at(0)
	old := c.conn_info().pass
	e.clk.add(100)
	c.drop()
	assert wait_until(2000, fn [mut e] () bool {
		return e.sink.state(1) == 'connecting'
	})
	assert wait_until(4000, fn [e] () bool {
		mut n := e.net
		return n.count() == 2
	})
	mut next := e.net.at(1)
	assert wait_until(2000, fn [mut next] () bool {
		return next.packets().len >= 1
	})
	assert next.conn_info().pass != old
	assert wait_until(2000, fn [mut e] () bool {
		return e.sink.state(1) == 'connected'
	})
}

fn test_unreachable_broker_reports_error_and_keeps_retrying() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.net.unreach['127.0.0.1:1883'] = true
	e.p.handle(cfg_cmd([tcp_broker()], t_prv, 'BYG'))
	assert wait_until(2000, fn [mut e] () bool {
		r := e.sink.row(2) or { return false }
		return r.state == 'error' && r.err.contains('connection refused')
	})
	e.net.mu.lock()
	e.net.unreach['127.0.0.1:1883'] = false
	e.net.mu.unlock()
	assert wait_until(4000, fn [mut e] () bool {
		return e.sink.state(2) == 'connected'
	})
}

fn test_packets_before_config_and_unknown_commands_are_ignored() {
	mut e := new_env()
	defer { e.p.stop_all(false) }
	e.p.handle(MqttInCmd{ cmd: 'nope' })
	e.p.handle(MqttInCmd{ cmd: 'packet' }) // no payload
	e.p.handle(MqttInCmd{ cmd: 'packet', payload: 'x' }) // before any config
	assert e.net.count() == 0
}

fn test_status_payload_timestamp_and_unknowns() {
	c := MqttPubCore{
		iata:      'BYG'
		origin:    'N'
		origin_id: 'AB'
	}
	s := c.status_json('online', 1700000000)
	assert s.contains('"timestamp":"2023-11-14T22:13:20Z"')
	assert s.contains('"model":"unknown"') && s.contains('"firmware_version":"unknown"')
}

fn test_client_id_fits_mqtt_limit() {
	c := MqttPubCore{
		origin_id: t_pub
	}
	id := mqtt_client_id(c, 12345678)
	assert id.len <= 23
	assert id.starts_with('meshbbs_03a107bf_')
	assert mqtt_client_id(MqttPubCore{ origin_id: 'AB' }, 3) == 'meshbbs_ab_3'
}

// ---- the MqttPipe the daemon uses ----

@[heap]
struct StatusLog {
mut:
	states []string
}

fn test_native_pipe_json_lines_and_status() {
	mut sink_net := &FakeNet{}
	clk := &FakeClock{
		t: t_t0
	}
	mut pipe := new_native_pipe_with(sink_net.dialer(), clk.now_fn())!
	assert pipe.alive()
	cfg := json2.encode(MqttCfgCmd{
		cmd:       'config'
		iata:      'byg'
		origin:    'MESHBBS'
		origin_id: t_pub
		brokers:   [tcp_broker()]
	},
		escape_unicode: true
	)
	assert pipe.write_line(cfg)
	assert pipe.write_line('not json at all')
	log := &StatusLog{}
	assert wait_until(3000, fn [mut pipe, log] () bool {
		mut l := unsafe { log }
		for {
			line := pipe.read_status() or { break }
			m := json2.decode[MqttStatusMsg](line) or { continue }
			if m.t == 'status' && m.id == 2 {
				l.states << m.state
			}
		}
		return 'connected' in l.states
	})
	assert log.states[0] == 'connecting'
	assert pipe.write_line(json2.encode({
		'cmd':     'packet'
		'payload': '{"a":"é"}'
	},
		escape_unicode: true
	))
	mut c := sink_net.at(0)
	assert wait_until(2000, fn [mut c] () bool {
		return c.publishes().len == 2
	})
	assert c.publishes()[1].payload == '{"a":"é"}'
	pipe.write_line('{"cmd":"stop"}')
	pipe.stop()
	assert !pipe.alive()
	assert c.is_closed() && c.said_goodbye()
}
