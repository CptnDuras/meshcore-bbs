# Data Model (SQLite)

Single SQLite database owned by the daemon. Schema grows by phase. All timestamps are
UTC epoch seconds unless noted.

## Phase 0 — packet log

```sql
CREATE TABLE packet_log (
    id            INTEGER PRIMARY KEY,
    ts            INTEGER NOT NULL,        -- epoch secs when received/sent
    direction     TEXT NOT NULL,           -- 'in' (from radio) | 'out' (to radio)
    code          INTEGER NOT NULL,        -- first byte of frame payload
    code_name     TEXT,                    -- e.g. 'RESP_CODE_SELF_INFO' (best effort)
    raw_hex       TEXT NOT NULL            -- full frame payload as hex
);
```

## Phase 0/1 — nodes (contacts we have heard)

```sql
CREATE TABLE node (
    pubkey_prefix TEXT PRIMARY KEY,        -- hex of first 6 bytes of pubkey
    pubkey_full   TEXT,                    -- hex of full 32-byte key, if known
    name          TEXT,                    -- advertised name, if known
    first_seen    INTEGER NOT NULL,
    last_seen     INTEGER NOT NULL,
    last_snr      REAL,                    -- from V3 message frames, if present
    last_path_len INTEGER
);
```

## Phase 1 — BBS boards and messages

```sql
CREATE TABLE board (
    name          TEXT PRIMARY KEY,        -- e.g. 'general', 'swap', 'alerts'
    created_ts    INTEGER NOT NULL,
    description   TEXT
);

CREATE TABLE bbs_message (
    id            INTEGER PRIMARY KEY,
    board_name    TEXT NOT NULL REFERENCES board(name),
    author_prefix TEXT NOT NULL,           -- pubkey_prefix of poster
    author_name   TEXT,                    -- cached display name
    body          TEXT NOT NULL,
    posted_ts     INTEGER NOT NULL
);
CREATE INDEX idx_bbs_board_ts ON bbs_message(board_name, posted_ts);
```

## Phase 2 — services

```sql
CREATE TABLE checkin (
    id            INTEGER PRIMARY KEY,
    node_prefix   TEXT NOT NULL,
    status        TEXT,                    -- freeform, e.g. 'OK', 'need water'
    ts            INTEGER NOT NULL
);

-- "LAST <node>" is answered from node.last_seen; no separate table needed.
-- WX source (sensor vs cached forecast) TBD; add table when the source is decided.
```

## Phase 3 — bridge (for loop prevention / dedup)

```sql
CREATE TABLE bridged_message (
    id            INTEGER PRIMARY KEY,
    src_network   TEXT NOT NULL,           -- 'meshcore' | 'meshtastic'
    dst_network   TEXT NOT NULL,
    dedup_key     TEXT NOT NULL,           -- hash of (sender, timestamp, body)
    ts            INTEGER NOT NULL
);
CREATE UNIQUE INDEX idx_bridged_dedup ON bridged_message(dedup_key);
```

## Outbound send tracking (optional, Phase 1+)

To correlate `RESP_CODE_SENT` / `PUSH_CODE_SEND_CONFIRMED` ACKs with what we sent:

```sql
CREATE TABLE outbound (
    id            INTEGER PRIMARY KEY,
    ts            INTEGER NOT NULL,
    dest_prefix   TEXT,
    body          TEXT,
    ack_tag       TEXT,                    -- hex of 4-byte expected-ACK from RESP_CODE_SENT
    confirmed_ts  INTEGER,                 -- set when PUSH_CODE_SEND_CONFIRMED matches
    round_trip_ms INTEGER
);
```
