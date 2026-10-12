import io
import json

import ed25519_orlp as ed
import publisher as pub_mod
import pytest
from publisher import Publisher

PUB, PRV, _ = ed.ed25519_create_keypair(bytes(range(32)))
PUBHEX = PUB.hex().upper()
PRVHEX = PRV.hex()


class FakeResult:
    rc = 0


class FakeClient:
    def __init__(self, client_id, transport):
        self.client_id = client_id
        self.transport = transport
        self.userpw = None
        self.will = None
        self.tls = False
        self.ws_path = None
        self.connected_to = None
        self.published = []
        self.loop_started = False
        self.disconnected = False
        self.reconnected = 0
        self.on_connect = None
        self.on_disconnect = None

    def username_pw_set(self, u, p=None):
        self.userpw = (u, p)

    def will_set(self, topic, payload, qos=0, retain=False):
        self.will = (topic, payload, qos, retain)

    def tls_set(self, *a, **k):
        self.tls = True

    def ws_set_options(self, path="/", headers=None):
        self.ws_path = path

    def reconnect_delay_set(self, *a, **k):
        pass

    def connect_async(self, host, port, keepalive=60):
        self.connected_to = (host, port, keepalive)

    def loop_start(self):
        self.loop_started = True

    def loop_stop(self):
        self.loop_started = False

    def publish(self, topic, payload, qos=0, retain=False):
        self.published.append((topic, payload, qos, retain))
        return FakeResult()

    def disconnect(self):
        self.disconnected = True

    def reconnect(self):
        self.reconnected += 1

    # test helper: simulate the broker accepting the connection
    def fire_connect(self):
        self.on_connect(self, None, None, 0, None)

    def fire_disconnect(self):
        self.on_disconnect(self, None, None, 0, None)


class ListSink:
    """Captures status events like the real stdout sink would emit them."""

    def __init__(self):
        self.events = []

    def set(self, broker_id, state, error, published, now):
        self.events.append(("set", broker_id, state, error, published))

    def delete(self, broker_id):
        self.events.append(("delete", broker_id))


@pytest.fixture
def env():
    sink = ListSink()
    clients = []

    def factory(client_id, transport):
        c = FakeClient(client_id, transport)
        clients.append(c)
        return c

    clock = {"t": 1_760_000_000}
    p = Publisher(factory, sink, now=lambda: clock["t"])
    return p, clients, sink, clock


def cfg(brokers, key=PRVHEX, iata="BYG"):
    return {"cmd": "config", "iata": iata, "origin": "MESHBBS", "origin_id": PUBHEX,
            "model": "Heltec V3", "fw": "1.17.1", "key": key, "brokers": brokers}


WSS = {"id": 1, "name": "meshmapper", "host": "mqtt.meshmapper.net", "port": 443,
       "transport": "wss", "path": "/", "auth": "token", "audience": "mqtt.meshmapper.net",
       "username": "", "password": ""}
TCP = {"id": 2, "name": "local", "host": "127.0.0.1", "port": 1883, "transport": "tcp",
       "path": "", "auth": "none", "audience": "", "username": "", "password": ""}


def rows(sink):
    """Latest (broker_id, state, error, published) per broker, like the DB table."""
    cur = {}
    for ev in sink.events:
        if ev[0] == "set":
            cur[ev[1]] = (ev[1], ev[2], ev[3], ev[4])
        else:
            cur.pop(ev[1], None)
    return [cur[k] for k in sorted(cur)]


def test_wss_token_broker_setup(env):
    p, clients, db, _ = env
    p.handle(cfg([WSS]))
    assert len(clients) == 1
    c = clients[0]
    assert c.transport == "websockets"
    assert c.tls and c.ws_path == "/"
    assert c.connected_to == ("mqtt.meshmapper.net", 443, 60)
    assert c.loop_started
    user, password = c.userpw
    assert user == "v1_" + PUBHEX
    assert password.count(".") == 2
    topic, payload, qos, retain = c.will
    assert topic == f"meshcore/BYG/{PUBHEX}/status"
    assert json.loads(payload)["status"] == "offline"
    assert retain is True
    assert rows(db) == [(1, "connecting", "", 0)]


def test_tcp_none_broker_has_no_tls_or_login(env):
    p, clients, db, _ = env
    p.handle(cfg([TCP]))
    c = clients[0]
    assert c.transport == "tcp"
    assert not c.tls
    assert c.userpw is None
    assert c.connected_to == ("127.0.0.1", 1883, 60)


def test_password_auth(env):
    p, clients, db, _ = env
    b = dict(TCP, auth="password", username="u", password="pw")
    p.handle(cfg([b]))
    assert clients[0].userpw == ("u", "pw")


def test_online_status_on_connect(env):
    p, clients, db, _ = env
    p.handle(cfg([TCP]))
    clients[0].fire_connect()
    topic, payload, qos, retain = clients[0].published[0]
    assert topic == f"meshcore/BYG/{PUBHEX}/status"
    assert json.loads(payload)["status"] == "online"
    assert retain is True
    assert rows(db)[0][1] == "connected"


def test_packets_only_go_to_connected_brokers(env):
    p, clients, db, _ = env
    p.handle(cfg([WSS, TCP]))
    clients[1].fire_connect()  # only the local broker is up
    clients[1].published.clear()
    p.handle({"cmd": "packet", "payload": '{"x":1}'})
    p.tick()  # counters are flushed to the DB by the once-a-second tick
    assert clients[0].published == []
    assert clients[1].published == [(f"meshcore/BYG/{PUBHEX}/packets", '{"x":1}', 0, False)]
    assert rows(db)[1][3] == 1  # published counter for broker 2
    # the disconnected broker's count is untouched
    assert rows(db)[0][3] == 0


def test_token_broker_without_key_errors_and_creates_no_client(env):
    p, clients, db, _ = env
    p.handle(cfg([WSS], key=""))
    assert clients == []
    r = rows(db)[0]
    assert r[1] == "error" and "key" in r[2]


def test_bad_key_is_reported_not_raised(env):
    p, clients, db, _ = env
    p.handle(cfg([WSS], key="abcd"))
    assert clients == []
    assert rows(db)[0][1] == "error"


def test_reconfig_restarts_only_changed_brokers(env):
    p, clients, db, _ = env
    p.handle(cfg([WSS, TCP]))
    first_wss, first_tcp = clients
    # change only the local broker's port
    p.handle(cfg([WSS, dict(TCP, port=1884)]))
    assert not first_wss.disconnected  # untouched
    assert first_tcp.disconnected
    assert len(clients) == 3
    assert clients[2].connected_to == ("127.0.0.1", 1884, 60)


def test_reconfig_removing_broker_disconnects_it_and_clears_status(env):
    p, clients, db, _ = env
    p.handle(cfg([WSS, TCP]))
    clients[1].fire_connect()
    p.handle(cfg([WSS]))
    assert clients[1].disconnected
    # offline status published before leaving
    assert any(json.loads(x[1])["status"] == "offline" for x in clients[1].published)
    assert [r[0] for r in rows(db)] == [1]


def test_iata_change_restarts_everything(env):
    p, clients, db, _ = env
    p.handle(cfg([TCP]))
    p.handle(cfg([TCP], iata="SHR"))
    assert clients[0].disconnected
    assert clients[1].will[0] == f"meshcore/SHR/{PUBHEX}/status"


def test_stop_publishes_offline_and_disconnects(env):
    p, clients, db, _ = env
    p.handle(cfg([TCP]))
    clients[0].fire_connect()
    p.handle({"cmd": "stop"})
    assert clients[0].disconnected
    assert json.loads(clients[0].published[-1][1])["status"] == "offline"
    assert rows(db)[0][1] == "stopped"


def test_token_refreshed_before_expiry(env):
    p, clients, db, clock = env
    p.handle(cfg([WSS]))
    c = clients[0]
    c.fire_connect()
    old = c.userpw[1]
    clock["t"] += 600
    p.tick()
    assert c.userpw[1] == old  # still fresh
    clock["t"] += 3000  # now past the refresh threshold
    p.tick()
    assert c.userpw[1] != old
    assert c.reconnected == 1


def test_reconnect_after_drop_uses_fresh_token(env):
    p, clients, db, clock = env
    p.handle(cfg([WSS]))
    c = clients[0]
    c.fire_connect()
    old = c.userpw[1]
    clock["t"] += 100
    c.fire_disconnect()
    assert rows(db)[0][1] == "connecting"
    assert c.userpw[1] != old  # new iat -> new token for the retry


def test_unknown_and_malformed_commands_are_ignored(env):
    p, clients, db, _ = env
    p.handle({"cmd": "nope"})
    p.handle({"cmd": "packet"})  # no payload
    p.handle({"cmd": "packet", "payload": "x"})  # before any config
    assert clients == []


def test_main_loop_parses_lines(env):
    p, clients, db, _ = env
    lines = [json.dumps(cfg([TCP])), "not json", json.dumps({"cmd": "stop"})]
    pub_mod.run_lines(p, iter(lines))
    assert clients[0].disconnected


def test_stdout_sink_emits_json_lines():
    buf = io.StringIO()
    s = pub_mod.StatusSink(buf)
    s.set(3, "connected", "", 12, 1760000000)
    s.delete(3)
    lines = [json.loads(x) for x in buf.getvalue().splitlines()]
    assert lines[0] == {"t": "status", "id": 3, "state": "connected", "error": "",
                        "published": 12, "ts": 1760000000}
    assert lines[1] == {"t": "delete", "id": 3}
