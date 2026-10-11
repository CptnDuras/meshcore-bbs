module main

// ORM models. Annotated structs work with V's ORM against SQLite now and
// Postgres later (same structs, different connection) — the pluggable goal.

// Session states for the per-node state machine.
pub const state_guest = 'guest'
pub const state_main = 'main' // authenticated main menu
pub const state_reading = 'reading' // paging through a board
pub const state_entry = 'entry' // multi-packet message entry in progress

@[table: 'users']
pub struct User {
pub mut:
	id        int    @[primary; sql: serial]
	handle    string @[unique]
	pass_hash string // bcrypt
	perm      int    // Perm level: 0=unverified 1=twit 2=user 3=aide 4=sysop
	banned    bool
	bio       string
	created   i64    // epoch secs
	last_seen i64
}

@[table: 'boards']
pub struct Board {
pub mut:
	id      int    @[primary; sql: serial]
	name    string @[unique]
	descr   string
	created i64
}

@[table: 'bbs_messages']
pub struct BbsMessage {
pub mut:
	id          int    @[primary; sql: serial]
	board_id    int
	author      string // handle, or pubkey prefix for guests (guests can't post in v1)
	subject     string
	body        string
	posted      i64
	reply_to    int // 0 = top-level, else parent message id
}

// Session persists a node's place in the BBS between mesh turns (messages can
// be minutes apart). Keyed by the sender's pubkey prefix (their identity).
@[table: 'sessions']
pub struct Session {
pub mut:
	id            int    @[primary; sql: serial]
	pubkey_prefix string @[unique]
	state         string // state_guest / state_main / state_reading / state_entry
	handle        string // '' when guest
	current_board int    // board id when reading, else 0
	page_offset   int    // pagination cursor within current view
	entry_mode    string // '' none, 'post' entering a room post, 'mail' entering mail
	entry_buffer  string // accumulated multi-packet message body
	entry_subject string // subject captured for the entry
	mail_to       string // recipient handle when entry_mode == 'mail'
	greeted       bool   // true once the first-contact greeting has been shown
	last_seen     i64
}

// Mail: a private user-to-user message.
@[table: 'mail']
pub struct Mail {
pub mut:
	id        int    @[primary; sql: serial]
	to_handle string
	from_handle string
	body      string
	sent      i64
	is_read   bool
}

@[table: 'last_read']
pub struct LastRead {
pub mut:
	id       int @[primary; sql: serial]
	user_id  int
	board_id int
	last_msg int // highest message id read on this board
}

// Oneliner: a short public quip on the graffiti wall.
@[table: 'oneliners']
pub struct Oneliner {
pub mut:
	id     int    @[primary; sql: serial]
	author string
	text   string
	posted i64
}

// Bulletin: a sysop-posted read-only notice shown on login / via BULLETIN.
@[table: 'bulletins']
pub struct Bulletin {
pub mut:
	id      int    @[primary; sql: serial]
	title   string
	body    string
	posted  i64
}

// Poll: an interactive vote. Options are stored as a newline-separated list in
// `options` (mesh packets are tiny; a child table would cost extra round-trips
// and the option set is small and fixed at creation time).
@[table: 'polls']
pub struct Poll {
pub mut:
	id       int    @[primary; sql: serial]
	question string
	options  string // '\n'-joined option texts, index 1..N as shown to users
	author   string // handle of creator
	created  i64
	closed   bool   // when true, no more votes are accepted
}

// PollVote: one vote by one voter (pubkey prefix) on one poll. The unique
// (poll_id, voter) pairing is enforced in the store to prevent double-voting.
@[table: 'poll_votes']
pub struct PollVote {
pub mut:
	id      int    @[primary; sql: serial]
	poll_id int
	voter   string // pubkey prefix (works for guests and users alike)
	choice  int    // 1-based option index
	voted   i64
}

// Interaction is a durable audit-log row for every inbound turn the BBS
// handles. This table is INTERNAL/sysop-only: it is written from Engine.handle
// but is deliberately NOT reachable from any user-facing command in the
// dispatch table, so a caller using the BBS can never read or touch it.
@[table: 'interactions']
pub struct Interaction {
pub mut:
	id            int    @[primary; sql: serial]
	ts            i64    // epoch secs when handled
	pubkey_prefix string // sender node identity
	handle        string // resolved user handle, or '' for guest
	command       string // first token, upper-cased (e.g. NEWS, VOTE, POLL)
	text          string // full raw inbound text
	reply_len     int    // length of the reply produced (bytes)
}

// Channel is an entry in the channel directory (Spec 11 / TC2-BBS parity):
// users publish community channels so newcomers can discover them. `info`
// holds an optional join hint (channel URL, PSK, or free text).
@[table: 'channels']
pub struct Channel {
pub mut:
	id      int    @[primary; sql: serial]
	name    string @[unique]
	descr   string
	info    string // optional: channel URL / PSK / join hint
	author  string // handle that added it
	created i64
}

// NodeName maps a node's pubkey prefix to its advertised friendly name,
// synced from the radio's contact list (CMD_GET_CONTACTS) every 15 minutes.
@[table: 'node_names']
pub struct NodeName {
pub mut:
	id            int    @[primary; sql: serial]
	pubkey_prefix string @[unique]
	name          string
	contact_type  int
	last_advert   i64 // node's own last-advert timestamp (from the contact entry)
	updated       i64 // when we last refreshed this row
}

// MeshTraffic is a passive observation of any packet the radio surfaces to us —
// including traffic NOT directed at this node (adverts, path updates, acks,
// channel/contact messages we overhear). Used for mesh-health monitoring.
@[table: 'mesh_traffic']
pub struct MeshTraffic {
pub mut:
	id            int    @[primary; sql: serial]
	ts            i64    // when observed (epoch secs)
	kind          string // event type: advert / path / ack / chan_msg / dm / ...
	pubkey_prefix string // source node if known, else ''
	snr           f64    // signal-to-noise (dB) if the frame carried it, else 0
	path_len      int    // hop count if known, else 0
}

// UserMacro is a user-defined text-macro command: sending its name replies with
// its text. Safe by design — no scripting, just canned text. Scoped per owner.
@[table: 'user_macros']
pub struct UserMacro {
pub mut:
	id      int    @[primary; sql: serial]
	owner   string // handle that owns the macro
	name    string // command name (upper-cased), unique per owner
	text    string // reply text
	created i64
}

// UserPref is a simple per-user key/value preference (e.g. digest opt-in).
@[table: 'user_prefs']
pub struct UserPref {
pub mut:
	id    int    @[primary; sql: serial]
	owner string
	key   string
	val   string
}

// MailNotice guards proactive "you have mail" notices so we don't spam a node
// each time it advertises. Tracks when we last notified a handle and the unread
// count at that time (so a notice re-fires when new mail arrives or a cooldown
// elapses).
@[table: 'mail_notices']
pub struct MailNotice {
pub mut:
	id            int    @[primary; sql: serial]
	handle        string @[unique]
	last_notified i64
	last_count    int
}

// SentHeadline records a news headline already broadcast, so news aging can
// skip it next time (each send surfaces fresh items).
@[table: 'sent_headlines']
pub struct SentHeadline {
pub mut:
	id    int    @[primary; sql: serial]
	title string @[unique]
	sent  i64
}

// target_kind values for outbound + scheduled messages.
pub const target_chan = 'chan' // target is a channel index (as string, e.g. "0")
pub const target_dm = 'dm' // target is a node pubkey prefix (hex)

// sched_kind values for scheduled messages.
pub const sched_onetime = 'onetime'
pub const sched_interval = 'interval'
pub const sched_daily = 'daily'

// source values: where a scheduled message's content comes from at send time.
//   static  -> use the row's `text` verbatim
//   wx      -> live weather; spacewx -> space weather; news -> local headlines
//   fortune -> a random fortune; digest -> wx + spacewx + news combined
pub const src_static = 'static'
pub const src_wx = 'wx'
pub const src_spacewx = 'spacewx'
pub const src_news = 'news'
pub const src_fortune = 'fortune'
pub const src_digest = 'digest'
pub const src_forecast = 'forecast'

// OutboundMessage is a queued send the daemon (sole owner of the serial radio)
// drains. Both scheduled messages and backend/on-demand broadcasts enqueue here
// so there is a single, testable send path.
@[table: 'outbound_messages']
pub struct OutboundMessage {
pub mut:
	id          int    @[primary; sql: serial]
	target_kind string // target_chan | target_dm
	target      string // channel index (as string) or node pubkey prefix
	text        string
	created     i64
	sent        bool
	sent_ts     i64
}

// ScheduledMessage is a DB-backed schedule the daemon evaluates each tick. When
// due, it enqueues an OutboundMessage. Three kinds:
//   onetime  -> fire once at run_at (epoch secs), then disable
//   interval -> every interval_secs
//   daily    -> at daily_minute (minutes past local midnight)
@[table: 'scheduled_messages']
pub struct ScheduledMessage {
pub mut:
	id            int    @[primary; sql: serial]
	target_kind   string // target_chan | target_dm
	target        string // channel index or node pubkey prefix
	text          string
	source        string = 'static' // static | wx | spacewx | news | fortune | digest
	sched_kind    string // sched_onetime | sched_interval | sched_daily
	interval_secs i64    // for interval
	daily_minute  int    // for daily (0..1439 local)
	run_at        i64    // for onetime (epoch secs)
	last_run      i64    // 0 = never
	enabled       bool
	created       i64
}

// --- MQTT observer (optional; OFF by default) ---
// All configuration lives in the shared DB so the web UI process can edit it
// and the daemon can hot-reload it. The node's private key is NEVER stored.

// MqttSetting is a key/value row. Keys: enabled ('1'/'0'), iata, rev.
@[table: 'mqtt_settings']
pub struct MqttSetting {
pub mut:
	id  int    @[primary; sql: serial]
	key string @[unique]
	val string
}

// MqttBroker is one upstream broker the observer publishes to.
//   transport: tcp | tls (MQTT over TLS) | ws | wss
//   auth:      none | password | token (JWT signed with the node's key)
@[table: 'mqtt_brokers']
pub struct MqttBroker {
pub mut:
	id        int    @[primary; sql: serial]
	name      string
	enabled   bool
	host      string
	port      int
	transport string = 'tcp'
	path      string // websocket path, e.g. /mqtt
	auth      string = 'none'
	username  string
	password  string
	audience  string // JWT audience for token auth
	created   i64
}

// MqttStatus is telemetry written by the publisher: one row per broker.
@[table: 'mqtt_status']
pub struct MqttStatus {
pub mut:
	id         int    @[primary; sql: serial]
	broker_id  int    @[unique]
	state      string // connecting | connected | error | stopped
	last_error string
	published  i64
	updated    i64
}
