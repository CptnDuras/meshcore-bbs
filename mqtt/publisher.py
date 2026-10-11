#!/usr/bin/env python3
"""meshbbs MQTT observer publisher.

Spawned by the meshbbs daemon only while MQTT is enabled. It reads JSON lines
on stdin and publishes to the configured brokers:

  {"cmd":"config","iata":..,"origin":..,"origin_id":<pubkey hex>,"model":..,
   "fw":..,"key":<64-byte private key hex, or "">,"brokers":[{...}, ...]}
  {"cmd":"packet","payload":"<json string>"}      -> .../packets
  {"cmd":"stop"}                                  -> offline status, exit

The private key arrives over the pipe and lives only in this process's memory.
Per-broker connection state is written to the shared DB (table mqtt_status)
for the web UI. Usage: publisher.py <path-to-meshbbs.db>
"""
import json
import queue
import sqlite3
import sys
import threading
import time

import auth

CLIENT_VERSION = "meshbbs-mqtt/1"
KEEPALIVE = 60
TOKEN_TTL = 3600
TOKEN_REFRESH_AFTER = 3000  # re-issue well before the 1h expiry


def log(msg):
    print(f"[publisher] {msg}", file=sys.stderr, flush=True)


class StatusSink:
    """Writes per-broker telemetry into the shared SQLite DB."""

    def __init__(self, path):
        self.path = path

    def _exec(self, fn):
        try:
            conn = sqlite3.connect(self.path, timeout=5)
            try:
                fn(conn)
                conn.commit()
            finally:
                conn.close()
        except sqlite3.Error as e:
            log(f"status write failed: {e}")

    def set(self, broker_id, state, error, published, now):
        def go(conn):
            cur = conn.execute(
                "UPDATE mqtt_status SET state=?, last_error=?, published=?, updated=? WHERE broker_id=?",
                (state, error, published, now, broker_id))
            if cur.rowcount == 0:
                conn.execute(
                    "INSERT INTO mqtt_status (broker_id, state, last_error, published, updated)"
                    " VALUES (?,?,?,?,?)", (broker_id, state, error, published, now))
        self._exec(go)

    def delete(self, broker_id):
        self._exec(lambda conn: conn.execute("DELETE FROM mqtt_status WHERE broker_id=?", (broker_id,)))


class Conn:
    def __init__(self, broker, fingerprint):
        self.broker = broker
        self.fingerprint = fingerprint
        self.client = None
        self.connected = False
        self.published = 0
        self.dirty = False
        self.token_time = 0


class Publisher:
    def __init__(self, client_factory, sink, now=time.time):
        self.factory = client_factory
        self.sink = sink
        self.now = now
        self.core = None  # (iata, origin, origin_id, model, fw, key)
        self.conns = {}

    # ---- helpers ----
    def _ts(self):
        return int(self.now())

    def _topic(self, kind):
        return f"meshcore/{self.core[0]}/{self.core[2].upper()}/{kind}"

    def _status_json(self, status):
        iata, origin, origin_id, model, fw, _key = self.core
        return json.dumps({
            "status": status,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self._ts())),
            "origin": origin,
            "origin_id": origin_id,
            "model": model or "unknown",
            "firmware_version": fw or "unknown",
            "client_version": CLIENT_VERSION,
        })

    def _report(self, conn, state, error=""):
        self.sink.set(conn.broker["id"], state, error, conn.published, self._ts())
        conn.dirty = False

    def _credentials(self, broker):
        """(username, password) for the broker, or raises ValueError."""
        if broker["auth"] == "token":
            key = self.core[5]
            if not key:
                raise ValueError("no private key available from the radio (token auth needs key export)")
            tok = auth.create_token(self.core[2], key, audience=broker["audience"],
                                    ttl=TOKEN_TTL, now=self._ts(), client=CLIENT_VERSION)
            return auth.username(self.core[2]), tok
        if broker["auth"] == "password":
            return broker["username"], broker["password"]
        return None, None

    # ---- lifecycle ----
    def _start(self, broker, fingerprint):
        conn = Conn(broker, fingerprint)
        self.conns[broker["id"]] = conn
        try:
            creds = self._credentials(broker)
        except ValueError as e:
            self._report(conn, "error", str(e))
            conn.client = None
            return
        tls = broker["transport"] in ("tls", "wss")
        ws = broker["transport"] in ("ws", "wss")
        client_id = ("meshbbs_" + self.core[2][:8].lower() + "_" + str(broker["id"]))[:23]
        c = self.factory(client_id, "websockets" if ws else "tcp")
        conn.client = c
        if creds[0]:
            c.username_pw_set(*creds)
            if broker["auth"] == "token":
                conn.token_time = self._ts()
        c.will_set(self._topic("status"), self._status_json("offline"), qos=0, retain=True)
        if tls:
            c.tls_set()
        if ws:
            c.ws_set_options(path=broker.get("path") or "/")
        c.reconnect_delay_set(min_delay=1, max_delay=120)
        c.on_connect = lambda cl, ud, fl, rc, pr=None, _c=conn: self._on_connect(_c, rc)
        c.on_disconnect = lambda cl, ud, *a, _c=conn: self._on_disconnect(_c)
        self._report(conn, "connecting")
        c.connect_async(broker["host"], int(broker["port"]), keepalive=KEEPALIVE)
        c.loop_start()

    def _stop(self, conn, state="stopped"):
        c = conn.client
        if c is not None:
            if conn.connected:
                try:
                    c.publish(self._topic("status"), self._status_json("offline"), qos=0, retain=True)
                except Exception as e:  # noqa: BLE001
                    log(f"offline publish failed: {e}")
            try:
                c.disconnect()
                c.loop_stop()
            except Exception as e:  # noqa: BLE001
                log(f"disconnect failed: {e}")
        conn.connected = False
        if state:
            self._report(conn, state)

    def _on_connect(self, conn, rc):
        failed = rc.is_failure if hasattr(rc, "is_failure") else rc != 0
        if failed:
            self._report(conn, "error", f"connect refused: {rc}")
            return
        conn.connected = True
        try:
            conn.client.publish(self._topic("status"), self._status_json("online"), qos=0, retain=True)
        except Exception as e:  # noqa: BLE001
            log(f"online publish failed: {e}")
        self._report(conn, "connected")

    def _on_disconnect(self, conn):
        conn.connected = False
        if conn.broker["auth"] == "token" and conn.client is not None:
            try:  # paho reconnects with the stored password: make it a fresh token
                conn.client.username_pw_set(*self._credentials(conn.broker))
                conn.token_time = self._ts()
            except ValueError:
                pass
        self._report(conn, "connecting")

    # ---- command handling ----
    def handle(self, msg):
        cmd = msg.get("cmd")
        if cmd == "config":
            self._config(msg)
        elif cmd == "packet":
            self._packet(msg)
        elif cmd == "stop":
            self.stop_all()

    def _config(self, msg):
        core = (str(msg.get("iata", "")).upper(), msg.get("origin", ""), str(msg.get("origin_id", "")).upper(),
                msg.get("model", ""), msg.get("fw", ""), msg.get("key", ""))
        old_core = self.core
        if old_core is not None and old_core != core:
            self.stop_all(clear=True)
        self.core = core
        wanted = {b["id"]: b for b in msg.get("brokers", [])}
        for bid in list(self.conns):
            if bid not in wanted:
                self._stop(self.conns[bid], state=None)
                self.sink.delete(bid)
                del self.conns[bid]
        for bid, b in wanted.items():
            fp = json.dumps(b, sort_keys=True)
            cur = self.conns.get(bid)
            if cur is not None and cur.fingerprint == fp:
                continue
            if cur is not None:
                self._stop(cur, state=None)
            self._start(b, fp)

    def _packet(self, msg):
        payload = msg.get("payload")
        if self.core is None or not isinstance(payload, str):
            return
        topic = self._topic("packets")
        for conn in self.conns.values():
            if not conn.connected:
                continue
            try:
                conn.client.publish(topic, payload, qos=0, retain=False)
                conn.published += 1
                conn.dirty = True
            except Exception as e:  # noqa: BLE001
                log(f"publish to {conn.broker['name']} failed: {e}")

    def stop_all(self, clear=False):
        for conn in list(self.conns.values()):
            self._stop(conn, state=None if clear else "stopped")
        if clear:
            self.conns = {}

    def tick(self):
        """Called about once a second: refresh tokens, flush counters."""
        now = self._ts()
        for conn in self.conns.values():
            b = conn.broker
            if (b["auth"] == "token" and conn.client is not None
                    and now - conn.token_time >= TOKEN_REFRESH_AFTER):
                try:
                    conn.client.username_pw_set(*self._credentials(b))
                    conn.token_time = now
                    if conn.connected:
                        conn.client.reconnect()
                except Exception as e:  # noqa: BLE001
                    log(f"token refresh for {b['name']} failed: {e}")
            if conn.dirty:
                self._report(conn, "connected" if conn.connected else "connecting")


def run_lines(pub, lines):
    """Feed command lines to the publisher. Returns True once 'stop' is seen."""
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            log("ignoring malformed line")
            continue
        if not isinstance(msg, dict):
            continue
        pub.handle(msg)
        if msg.get("cmd") == "stop":
            return True
    return False


def make_paho_client(client_id, transport):
    import paho.mqtt.client as mqtt
    return mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=client_id,
                       clean_session=True, transport=transport)


def main(argv):
    if len(argv) != 2:
        print("usage: publisher.py <meshbbs.db>", file=sys.stderr)
        return 2
    pub = Publisher(make_paho_client, StatusSink(argv[1]))
    q = queue.Queue()

    def reader():
        for line in sys.stdin:
            q.put(line)
        q.put(None)  # EOF: the daemon went away

    threading.Thread(target=reader, daemon=True).start()
    while True:
        try:
            line = q.get(timeout=1)
        except queue.Empty:
            pub.tick()
            continue
        if line is None:
            pub.stop_all()
            return 0
        if run_lines(pub, [line]):
            return 0
        pub.tick()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
