module main

import db.sqlite
import time

// Store is the pluggable persistence interface. The BBS logic depends only on
// this — never on a concrete database. SqliteStore implements it now; a
// PostgresStore can implement the same interface later with zero changes to
// the session/command logic.
pub interface Store {
mut:
	migrate() !
	// users
	get_user(handle string) ?User
	create_user(handle string, pass_hash string) !User
	get_or_create_node_user(pubkey_prefix string) !User
	claim_handle(old_handle string, new_handle string, pass_hash string) !
	set_user_pass(handle string, pass_hash string) !
	count_users() int
	set_user_perm(handle string, perm int) !
	set_user_banned(handle string, banned bool) !
	list_users() []User
	// boards
	list_boards() []Board
	get_board(name string) ?Board
	ensure_board(name string, descr string) !Board
	// messages
	post_message(board_id int, author string, subject string, body string, reply_to int) !BbsMessage
	board_messages(board_id int, limit int) []BbsMessage
	delete_message(id int) !
	// sessions
	load_session(pubkey_prefix string) ?Session
	save_session(s Session) !
	// read pointers / navigation
	get_last_read(user_id int, board_id int) int
	set_last_read(user_id int, board_id int, last_msg int) !
	unread_count(user_id int, board_id int) int
	messages_after(board_id int, after_id int, limit int) []BbsMessage
	// mail
	send_mail(to_handle string, from_handle string, body string) !
	unread_mail_count(handle string) int
	list_mail(handle string, limit int) []Mail
	mark_mail_read(handle string) !
	// ensure_mailbox makes a minimal user record so mail can be stored for a
	// handle that has never logged in (empty pass_hash, perm=user). No-op if the
	// handle already exists.
	ensure_mailbox(handle string) !
	// conversation returns all mail between two handles in BOTH directions,
	// time-ordered oldest->newest (re-readable; does not touch unread state).
	conversation(handle_a string, handle_b string, limit int) []Mail
	// community features
	add_oneliner(author string, text string) !
	list_oneliners(limit int) []Oneliner
	add_bulletin(title string, body string) !
	list_bulletins(limit int) []Bulletin
	set_user_bio(handle string, bio string) !
	recent_users(limit int) []User
	touch_user_seen(handle string) !
	// polls
	create_poll(question string, options []string, author string) !Poll
	get_poll(id int) ?Poll
	list_polls(limit int) []Poll
	add_vote(poll_id int, voter string, choice int) !
	has_voted(poll_id int, voter string) bool
	poll_tally(poll_id int) []int
	close_poll(id int) !
	// interactions (internal audit log; not exposed to BBS callers)
	log_interaction(pubkey_prefix string, handle string, command string, text string, reply_len int) !
	recent_interactions(limit int) []Interaction
	interaction_senders() []string
	count_interactions() int
	// channel directory
	add_channel(name string, descr string, info string, author string) !Channel
	get_channel(name string) ?Channel
	list_channels(limit int) []Channel
	count_channels() int
	// stats
	count_messages() int
	count_boards() int
	count_polls() int
	active_nodes_since(since i64) int
	// node names (radio contact-list sync)
	upsert_node_name(pubkey_prefix string, name string, contact_type int, last_advert i64) !
	get_node_name(pubkey_prefix string) ?NodeName
	list_node_names(limit int) []NodeName
	count_node_names() int
	// passive mesh-traffic observations (mesh health)
	log_traffic(kind string, pubkey_prefix string, snr f64, path_len int) !
	count_traffic() int
	recent_traffic(limit int) []MeshTraffic
	traffic_nodes_since(since i64) int
	// outbound message queue (daemon drains; UI/scheduler enqueue)
	enqueue_outbound(target_kind string, target string, text string) !
	pending_outbound(limit int) []OutboundMessage
	mark_outbound_sent(id int) !
	count_outbound_pending() int
	// scheduled messages (DB-backed schedules the daemon evaluates)
	add_scheduled(m ScheduledMessage) !ScheduledMessage
	list_scheduled(limit int) []ScheduledMessage
	get_scheduled(id int) ?ScheduledMessage
	set_scheduled_enabled(id int, enabled bool) !
	delete_scheduled(id int) !
	mark_scheduled_run(id int, now i64) !
	count_scheduled_by_source(source string, daily_minute int) int
	// news aging
	headline_seen(title string) bool
	mark_headline_sent(title string) !
	seen_headlines() map[string]bool
	// user macros (custom text commands) + preferences
	add_macro(owner string, name string, text string) !
	get_macro(owner string, name string) ?UserMacro
	list_macros(owner string) []UserMacro
	delete_macro(owner string, name string) !
	set_pref(owner string, key string, val string) !
	get_pref(owner string, key string) ?string
	list_prefs(owner string) []UserPref
	// proactive mail-notice guard
	get_mail_notice(handle string) ?MailNotice
	record_mail_notice(handle string, count int, now i64) !
}

// new_store selects a backend from a config string.
//   'sqlite:path.db'  -> SqliteStore
//   'postgres://...'  -> (future) PostgresStore
pub fn new_store(config string) !Store {
	if config.starts_with('sqlite:') {
		path := config['sqlite:'.len..]
		mut s := &SqliteStore{
			path: path
		}
		s.open()!
		return s
	}
	return error('unsupported store config: ${config}')
}

// --- SqliteStore: the SQLite implementation via V's ORM ---
pub struct SqliteStore {
pub mut:
	path string
	db   sqlite.DB
}

fn (mut s SqliteStore) open() ! {
	s.db = sqlite.connect(s.path)!
}

pub fn (mut s SqliteStore) migrate() ! {
	sql s.db {
		create table User
		create table Board
		create table BbsMessage
		create table Session
		create table LastRead
		create table Mail
		create table Oneliner
		create table Bulletin
		create table Poll
		create table PollVote
		create table Interaction
		create table Channel
		create table NodeName
		create table MeshTraffic
		create table OutboundMessage
		create table ScheduledMessage
		create table SentHeadline
		create table UserMacro
		create table UserPref
		create table MailNotice
	}!
	// Lightweight column migrations for tables that predate a new field.
	// V's ORM `create table` is CREATE TABLE IF NOT EXISTS and never adds new
	// columns to an existing table, so add them explicitly here (idempotent:
	// only ALTER when the column is absent). SQLite has no ADD COLUMN IF NOT
	// EXISTS, so we probe PRAGMA table_info first.
	s.add_column_if_missing('scheduled_messages', 'source', "TEXT NOT NULL DEFAULT 'static'")!
	s.add_column_if_missing('sessions', 'greeted', 'INTEGER NOT NULL DEFAULT 0')!
}

// add_column_if_missing adds a column to a table only when it does not already
// exist, using PRAGMA table_info to check. No-op if the table is absent.
fn (mut s SqliteStore) add_column_if_missing(table string, column string, decl string) ! {
	info := s.db.exec("PRAGMA table_info(${table})") or { return }
	for row in info {
		// PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
		if row.vals.len > 1 && row.vals[1] == column {
			return // already present
		}
	}
	s.db.exec('ALTER TABLE ${table} ADD COLUMN ${column} ${decl}') or {
		return error('failed adding ${column} to ${table}: ${err}')
	}
}

pub fn (mut s SqliteStore) get_user(handle string) ?User {
	rows := sql s.db {
		select from User where handle == handle limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) create_user(handle string, pass_hash string) !User {
	// First registered user becomes SYSOP (bootstrap); others UNVERIFIED.
	perm := if s.count_users() == 0 { int(Perm.sysop) } else { int(Perm.unverified) }
	u := User{
		handle:    handle
		pass_hash: pass_hash
		perm:      perm
		created:   time.now().unix()
		last_seen: time.now().unix()
	}
	sql s.db {
		insert u into User
	}!
	return s.get_user(handle) or { return error('created user not found') }
}

pub fn (mut s SqliteStore) count_users() int {
	n := sql s.db {
		select count from User
	} or { 0 }
	return n
}

// node_handle is the auto-handle for a node that hasn't claimed a real one.
// Keeping the pubkey prefix in the handle lets the same node re-attach to its
// account on reconnect without any extra identity table.
fn node_handle(pubkey_prefix string) string {
	return 'node-${pubkey_prefix}'
}

// get_or_create_node_user auto-provisions a user-level account for a node on
// first contact (retiring mandatory registration). The very first account ever
// created still bootstraps as SYSOP; everyone else auto-registers as USER
// (posting allowed immediately — no verify gate).
pub fn (mut s SqliteStore) get_or_create_node_user(pubkey_prefix string) !User {
	h := node_handle(pubkey_prefix)
	if u := s.get_user(h) {
		return u
	}
	perm := if s.count_users() == 0 { int(Perm.sysop) } else { int(Perm.user) }
	u := User{
		handle:    h
		pass_hash: '' // no password until claimed
		perm:      perm
		created:   time.now().unix()
		last_seen: time.now().unix()
	}
	sql s.db {
		insert u into User
	}!
	return s.get_user(h) or { return error('auto-created user not found') }
}

// claim_handle renames a node's auto-account to a chosen handle and sets a
// password, so the user can LOGIN from another device (adopting this identity).
// Fails if the new handle is already taken.
pub fn (mut s SqliteStore) claim_handle(old_handle string, new_handle string, pass_hash string) ! {
	if _ := s.get_user(new_handle) {
		return error('handle "${new_handle}" is taken')
	}
	s.get_user(old_handle) or { return error('account not found') }
	sql s.db {
		update User set handle = new_handle, pass_hash = pass_hash where handle == old_handle
	}!
}

// set_user_pass updates the password hash for an existing account.
pub fn (mut s SqliteStore) set_user_pass(handle string, pass_hash string) ! {
	sql s.db {
		update User set pass_hash = pass_hash where handle == handle
	}!
}

pub fn (mut s SqliteStore) set_user_perm(handle string, perm int) ! {
	sql s.db {
		update User set perm = perm where handle == handle
	}!
}

pub fn (mut s SqliteStore) set_user_banned(handle string, banned bool) ! {
	sql s.db {
		update User set banned = banned where handle == handle
	}!
}

pub fn (mut s SqliteStore) list_users() []User {
	return sql s.db {
		select from User order by handle
	} or { []User{} }
}

pub fn (mut s SqliteStore) list_boards() []Board {
	return sql s.db {
		select from Board order by id
	} or { []Board{} }
}

pub fn (mut s SqliteStore) get_board(name string) ?Board {
	rows := sql s.db {
		select from Board where name == name limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) ensure_board(name string, descr string) !Board {
	if b := s.get_board(name) {
		return b
	}
	b := Board{
		name:    name
		descr:   descr
		created: time.now().unix()
	}
	sql s.db {
		insert b into Board
	}!
	return s.get_board(name) or { return error('created board not found') }
}

pub fn (mut s SqliteStore) post_message(board_id int, author string, subject string, body string, reply_to int) !BbsMessage {
	m := BbsMessage{
		board_id: board_id
		author:   author
		subject:  subject
		body:     body
		posted:   time.now().unix()
		reply_to: reply_to
	}
	sql s.db {
		insert m into BbsMessage
	}!
	rows := sql s.db {
		select from BbsMessage where board_id == board_id order by id desc limit 1
	} or { []BbsMessage{} }
	if rows.len == 0 {
		return error('posted message not found')
	}
	return rows[0]
}

pub fn (mut s SqliteStore) board_messages(board_id int, limit int) []BbsMessage {
	return sql s.db {
		select from BbsMessage where board_id == board_id order by id limit limit
	} or { []BbsMessage{} }
}

pub fn (mut s SqliteStore) delete_message(id int) ! {
	sql s.db {
		delete from BbsMessage where id == id
	}!
}

pub fn (mut s SqliteStore) get_last_read(user_id int, board_id int) int {
	rows := sql s.db {
		select from LastRead where user_id == user_id && board_id == board_id limit 1
	} or { []LastRead{} }
	if rows.len == 0 {
		return 0
	}
	return rows[0].last_msg
}

pub fn (mut s SqliteStore) set_last_read(user_id int, board_id int, last_msg int) ! {
	existing := sql s.db {
		select from LastRead where user_id == user_id && board_id == board_id limit 1
	} or { []LastRead{} }
	if existing.len == 0 {
		lr := LastRead{
			user_id:  user_id
			board_id: board_id
			last_msg: last_msg
		}
		sql s.db {
			insert lr into LastRead
		}!
	} else {
		rid := existing[0].id
		sql s.db {
			update LastRead set last_msg = last_msg where id == rid
		}!
	}
}

pub fn (mut s SqliteStore) unread_count(user_id int, board_id int) int {
	ptr := s.get_last_read(user_id, board_id)
	n := sql s.db {
		select count from BbsMessage where board_id == board_id && id > ptr
	} or { 0 }
	return n
}

pub fn (mut s SqliteStore) messages_after(board_id int, after_id int, limit int) []BbsMessage {
	return sql s.db {
		select from BbsMessage where board_id == board_id && id > after_id order by id limit limit
	} or { []BbsMessage{} }
}

pub fn (mut s SqliteStore) load_session(pubkey_prefix string) ?Session {
	rows := sql s.db {
		select from Session where pubkey_prefix == pubkey_prefix limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) save_session(sess Session) ! {
	// upsert by pubkey_prefix
	existing := sql s.db {
		select from Session where pubkey_prefix == sess.pubkey_prefix limit 1
	} or { []Session{} }
	mut x := sess
	x.last_seen = time.now().unix()
	if existing.len == 0 {
		sql s.db {
			insert x into Session
		}!
	} else {
		id := existing[0].id
		sql s.db {
			update Session set state = x.state, handle = x.handle, current_board = x.current_board,
			page_offset = x.page_offset, entry_mode = x.entry_mode, entry_buffer = x.entry_buffer,
			entry_subject = x.entry_subject, mail_to = x.mail_to, greeted = x.greeted, last_seen = x.last_seen
			where id == id
		}!
	}
}

pub fn (mut s SqliteStore) send_mail(to_handle string, from_handle string, body string) ! {
	m := Mail{
		to_handle:   to_handle
		from_handle: from_handle
		body:        body
		sent:        time.now().unix()
		is_read:     false
	}
	sql s.db {
		insert m into Mail
	}!
}

pub fn (mut s SqliteStore) unread_mail_count(handle string) int {
	n := sql s.db {
		select count from Mail where to_handle == handle && is_read == false
	} or { 0 }
	return n
}

pub fn (mut s SqliteStore) list_mail(handle string, limit int) []Mail {
	return sql s.db {
		select from Mail where to_handle == handle order by id limit limit
	} or { []Mail{} }
}

pub fn (mut s SqliteStore) mark_mail_read(handle string) ! {
	sql s.db {
		update Mail set is_read = true where to_handle == handle
	}!
}

// ensure_mailbox creates a minimal user record for `handle` if one does not
// already exist, so mail can be stored for a recipient that has never logged
// in. The record has an empty pass_hash (unclaimed) and perm=user. No-op when
// the handle already exists (never downgrades an existing account).
pub fn (mut s SqliteStore) ensure_mailbox(handle string) ! {
	if _ := s.get_user(handle) {
		return
	}
	u := User{
		handle:    handle
		pass_hash: '' // unclaimed: no password until the owner sets one
		perm:      int(Perm.user)
		created:   time.now().unix()
		last_seen: time.now().unix()
	}
	sql s.db {
		insert u into User
	}!
}

// conversation returns all mail exchanged between handle_a and handle_b in
// BOTH directions, ordered oldest->newest by id (a monotonic proxy for time).
// It does NOT modify unread state, so the thread stays re-readable.
pub fn (mut s SqliteStore) conversation(handle_a string, handle_b string, limit int) []Mail {
	rows := sql s.db {
		select from Mail where (to_handle == handle_a && from_handle == handle_b)
			|| (to_handle == handle_b && from_handle == handle_a) order by id limit limit
	} or { []Mail{} }
	return rows
}

pub fn (mut s SqliteStore) add_oneliner(author string, text string) ! {
	o := Oneliner{
		author: author
		text:   text
		posted: time.now().unix()
	}
	sql s.db {
		insert o into Oneliner
	}!
}

pub fn (mut s SqliteStore) list_oneliners(limit int) []Oneliner {
	return sql s.db {
		select from Oneliner order by id desc limit limit
	} or { []Oneliner{} }
}

pub fn (mut s SqliteStore) add_bulletin(title string, body string) ! {
	b := Bulletin{
		title:  title
		body:   body
		posted: time.now().unix()
	}
	sql s.db {
		insert b into Bulletin
	}!
}

pub fn (mut s SqliteStore) list_bulletins(limit int) []Bulletin {
	return sql s.db {
		select from Bulletin order by id desc limit limit
	} or { []Bulletin{} }
}

pub fn (mut s SqliteStore) set_user_bio(handle string, bio string) ! {
	sql s.db {
		update User set bio = bio where handle == handle
	}!
}

pub fn (mut s SqliteStore) recent_users(limit int) []User {
	return sql s.db {
		select from User order by last_seen desc limit limit
	} or { []User{} }
}

pub fn (mut s SqliteStore) touch_user_seen(handle string) ! {
	now := time.now().unix()
	sql s.db {
		update User set last_seen = now where handle == handle
	}!
}

// --- polls ---

pub fn (mut s SqliteStore) create_poll(question string, options []string, author string) !Poll {
	if options.len < 2 {
		return error('a poll needs at least 2 options')
	}
	p := Poll{
		question: question
		options:  options.join('\n')
		author:   author
		created:  time.now().unix()
		closed:   false
	}
	sql s.db {
		insert p into Poll
	}!
	rows := sql s.db {
		select from Poll order by id desc limit 1
	} or { []Poll{} }
	if rows.len == 0 {
		return error('created poll not found')
	}
	return rows[0]
}

pub fn (mut s SqliteStore) get_poll(id int) ?Poll {
	rows := sql s.db {
		select from Poll where id == id limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) list_polls(limit int) []Poll {
	return sql s.db {
		select from Poll order by id desc limit limit
	} or { []Poll{} }
}

pub fn (mut s SqliteStore) has_voted(poll_id int, voter string) bool {
	n := sql s.db {
		select count from PollVote where poll_id == poll_id && voter == voter
	} or { 0 }
	return n > 0
}

pub fn (mut s SqliteStore) add_vote(poll_id int, voter string, choice int) ! {
	// Guard: poll exists, is open, choice in range, and voter hasn't voted.
	poll := s.get_poll(poll_id) or { return error('no such poll') }
	if poll.closed {
		return error('poll is closed')
	}
	nopts := poll.options.split('\n').len
	if choice < 1 || choice > nopts {
		return error('choice out of range (1..${nopts})')
	}
	if s.has_voted(poll_id, voter) {
		return error('already voted')
	}
	v := PollVote{
		poll_id: poll_id
		voter:   voter
		choice:  choice
		voted:   time.now().unix()
	}
	sql s.db {
		insert v into PollVote
	}!
}

// poll_tally returns a slice of length == option count, where index i holds the
// number of votes for option (i+1).
pub fn (mut s SqliteStore) poll_tally(poll_id int) []int {
	poll := s.get_poll(poll_id) or { return []int{} }
	nopts := poll.options.split('\n').len
	mut counts := []int{len: nopts, init: 0}
	votes := sql s.db {
		select from PollVote where poll_id == poll_id
	} or { []PollVote{} }
	for v in votes {
		if v.choice >= 1 && v.choice <= nopts {
			counts[v.choice - 1]++
		}
	}
	return counts
}

pub fn (mut s SqliteStore) close_poll(id int) ! {
	sql s.db {
		update Poll set closed = true where id == id
	}!
}

// --- interactions (internal audit log) ---

pub fn (mut s SqliteStore) log_interaction(pubkey_prefix string, handle string, command string, text string, reply_len int) ! {
	row := Interaction{
		ts:            time.now().unix()
		pubkey_prefix: pubkey_prefix
		handle:        handle
		command:       command
		text:          text
		reply_len:     reply_len
	}
	sql s.db {
		insert row into Interaction
	}!
}

pub fn (mut s SqliteStore) recent_interactions(limit int) []Interaction {
	return sql s.db {
		select from Interaction order by id desc limit limit
	} or { []Interaction{} }
}

pub fn (mut s SqliteStore) count_interactions() int {
	n := sql s.db {
		select count from Interaction
	} or { 0 }
	return n
}

// interaction_senders returns the distinct sender pubkey prefixes seen.
pub fn (mut s SqliteStore) interaction_senders() []string {
	rows := sql s.db {
		select from Interaction order by id
	} or { []Interaction{} }
	mut seen := map[string]bool{}
	mut out := []string{}
	for r in rows {
		if !seen[r.pubkey_prefix] {
			seen[r.pubkey_prefix] = true
			out << r.pubkey_prefix
		}
	}
	return out
}

// --- channel directory ---

pub fn (mut s SqliteStore) add_channel(name string, descr string, info string, author string) !Channel {
	if _ := s.get_channel(name) {
		return error('channel "${name}" already listed')
	}
	c := Channel{
		name:    name
		descr:   descr
		info:    info
		author:  author
		created: time.now().unix()
	}
	sql s.db {
		insert c into Channel
	}!
	return s.get_channel(name) or { return error('added channel not found') }
}

pub fn (mut s SqliteStore) get_channel(name string) ?Channel {
	rows := sql s.db {
		select from Channel where name == name limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) list_channels(limit int) []Channel {
	return sql s.db {
		select from Channel order by name limit limit
	} or { []Channel{} }
}

pub fn (mut s SqliteStore) count_channels() int {
	n := sql s.db {
		select count from Channel
	} or { 0 }
	return n
}

// --- counts for STATS ---

pub fn (mut s SqliteStore) count_messages() int {
	n := sql s.db {
		select count from BbsMessage
	} or { 0 }
	return n
}

pub fn (mut s SqliteStore) count_boards() int {
	n := sql s.db {
		select count from Board
	} or { 0 }
	return n
}

pub fn (mut s SqliteStore) count_polls() int {
	n := sql s.db {
		select count from Poll
	} or { 0 }
	return n
}

// active_nodes_since returns the count of distinct interaction senders whose
// last activity is at or after `since` (epoch secs).
pub fn (mut s SqliteStore) active_nodes_since(since i64) int {
	rows := sql s.db {
		select from Interaction where ts >= since
	} or { []Interaction{} }
	mut seen := map[string]bool{}
	for r in rows {
		seen[r.pubkey_prefix] = true
	}
	return seen.len
}

// --- node names (radio contact-list sync) ---

pub fn (mut s SqliteStore) upsert_node_name(pubkey_prefix string, name string, contact_type int, last_advert i64) ! {
	now := time.now().unix()
	existing := sql s.db {
		select from NodeName where pubkey_prefix == pubkey_prefix limit 1
	} or { []NodeName{} }
	if existing.len == 0 {
		n := NodeName{
			pubkey_prefix: pubkey_prefix
			name:          name
			contact_type:  contact_type
			last_advert:   last_advert
			updated:       now
		}
		sql s.db {
			insert n into NodeName
		}!
	} else {
		id := existing[0].id
		sql s.db {
			update NodeName set name = name, contact_type = contact_type, last_advert = last_advert,
			updated = now where id == id
		}!
	}
}

pub fn (mut s SqliteStore) get_node_name(pubkey_prefix string) ?NodeName {
	rows := sql s.db {
		select from NodeName where pubkey_prefix == pubkey_prefix limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) list_node_names(limit int) []NodeName {
	return sql s.db {
		select from NodeName order by name limit limit
	} or { []NodeName{} }
}

pub fn (mut s SqliteStore) count_node_names() int {
	n := sql s.db {
		select count from NodeName
	} or { 0 }
	return n
}

// --- passive mesh traffic (mesh health) ---

pub fn (mut s SqliteStore) log_traffic(kind string, pubkey_prefix string, snr f64, path_len int) ! {
	row := MeshTraffic{
		ts:            time.now().unix()
		kind:          kind
		pubkey_prefix: pubkey_prefix
		snr:           snr
		path_len:      path_len
	}
	sql s.db {
		insert row into MeshTraffic
	}!
}

pub fn (mut s SqliteStore) count_traffic() int {
	n := sql s.db {
		select count from MeshTraffic
	} or { 0 }
	return n
}

pub fn (mut s SqliteStore) recent_traffic(limit int) []MeshTraffic {
	return sql s.db {
		select from MeshTraffic order by id desc limit limit
	} or { []MeshTraffic{} }
}

// traffic_nodes_since counts distinct source nodes seen in traffic since `since`.
pub fn (mut s SqliteStore) traffic_nodes_since(since i64) int {
	rows := sql s.db {
		select from MeshTraffic where ts >= since
	} or { []MeshTraffic{} }
	mut seen := map[string]bool{}
	for r in rows {
		if r.pubkey_prefix.len > 0 {
			seen[r.pubkey_prefix] = true
		}
	}
	return seen.len
}

// --- outbound message queue ---

pub fn (mut s SqliteStore) enqueue_outbound(target_kind string, target string, text string) ! {
	row := OutboundMessage{
		target_kind: target_kind
		target:      target
		text:        text
		created:     time.now().unix()
		sent:        false
		sent_ts:     0
	}
	sql s.db {
		insert row into OutboundMessage
	}!
}

pub fn (mut s SqliteStore) pending_outbound(limit int) []OutboundMessage {
	return sql s.db {
		select from OutboundMessage where sent == false order by id limit limit
	} or { []OutboundMessage{} }
}

pub fn (mut s SqliteStore) mark_outbound_sent(id int) ! {
	now := time.now().unix()
	sql s.db {
		update OutboundMessage set sent = true, sent_ts = now where id == id
	}!
}

pub fn (mut s SqliteStore) count_outbound_pending() int {
	n := sql s.db {
		select count from OutboundMessage where sent == false
	} or { 0 }
	return n
}

// --- scheduled messages ---

pub fn (mut s SqliteStore) add_scheduled(m ScheduledMessage) !ScheduledMessage {
	mut row := m
	row.created = time.now().unix()
	sql s.db {
		insert row into ScheduledMessage
	}!
	rows := sql s.db {
		select from ScheduledMessage order by id desc limit 1
	} or { []ScheduledMessage{} }
	if rows.len == 0 {
		return error('added schedule not found')
	}
	return rows[0]
}

pub fn (mut s SqliteStore) list_scheduled(limit int) []ScheduledMessage {
	return sql s.db {
		select from ScheduledMessage order by id limit limit
	} or { []ScheduledMessage{} }
}

pub fn (mut s SqliteStore) get_scheduled(id int) ?ScheduledMessage {
	rows := sql s.db {
		select from ScheduledMessage where id == id limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) set_scheduled_enabled(id int, enabled bool) ! {
	sql s.db {
		update ScheduledMessage set enabled = enabled where id == id
	}!
}

pub fn (mut s SqliteStore) delete_scheduled(id int) ! {
	sql s.db {
		delete from ScheduledMessage where id == id
	}!
}

pub fn (mut s SqliteStore) mark_scheduled_run(id int, now i64) ! {
	sql s.db {
		update ScheduledMessage set last_run = now where id == id
	}!
}

// count_scheduled_by_source counts schedules matching a source + daily_minute,
// used to seed the standing digests exactly once (idempotent across restarts).
pub fn (mut s SqliteStore) count_scheduled_by_source(source string, daily_minute int) int {
	n := sql s.db {
		select count from ScheduledMessage where source == source && daily_minute == daily_minute
	} or { 0 }
	return n
}

// --- news aging ---

pub fn (mut s SqliteStore) headline_seen(title string) bool {
	n := sql s.db {
		select count from SentHeadline where title == title
	} or { 0 }
	return n > 0
}

pub fn (mut s SqliteStore) mark_headline_sent(title string) ! {
	if s.headline_seen(title) {
		return
	}
	row := SentHeadline{
		title: title
		sent:  time.now().unix()
	}
	sql s.db {
		insert row into SentHeadline
	}!
}

pub fn (mut s SqliteStore) seen_headlines() map[string]bool {
	rows := sql s.db {
		select from SentHeadline
	} or { []SentHeadline{} }
	mut m := map[string]bool{}
	for r in rows {
		m[r.title] = true
	}
	return m
}

// --- user macros + preferences ---

pub fn (mut s SqliteStore) add_macro(owner string, name string, text string) ! {
	if _ := s.get_macro(owner, name) {
		// update existing
		sql s.db {
			update UserMacro set text = text where owner == owner && name == name
		}!
		return
	}
	m := UserMacro{
		owner:   owner
		name:    name
		text:    text
		created: time.now().unix()
	}
	sql s.db {
		insert m into UserMacro
	}!
}

pub fn (mut s SqliteStore) get_macro(owner string, name string) ?UserMacro {
	rows := sql s.db {
		select from UserMacro where owner == owner && name == name limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) list_macros(owner string) []UserMacro {
	return sql s.db {
		select from UserMacro where owner == owner order by name
	} or { []UserMacro{} }
}

pub fn (mut s SqliteStore) delete_macro(owner string, name string) ! {
	sql s.db {
		delete from UserMacro where owner == owner && name == name
	}!
}

pub fn (mut s SqliteStore) set_pref(owner string, key string, val string) ! {
	existing := sql s.db {
		select from UserPref where owner == owner && key == key limit 1
	} or { []UserPref{} }
	if existing.len == 0 {
		p := UserPref{
			owner: owner
			key:   key
			val:   val
		}
		sql s.db {
			insert p into UserPref
		}!
	} else {
		id := existing[0].id
		sql s.db {
			update UserPref set val = val where id == id
		}!
	}
}

pub fn (mut s SqliteStore) get_pref(owner string, key string) ?string {
	rows := sql s.db {
		select from UserPref where owner == owner && key == key limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0].val
}

pub fn (mut s SqliteStore) list_prefs(owner string) []UserPref {
	return sql s.db {
		select from UserPref where owner == owner order by key
	} or { []UserPref{} }
}

// --- proactive mail-notice guard ---

pub fn (mut s SqliteStore) get_mail_notice(handle string) ?MailNotice {
	rows := sql s.db {
		select from MailNotice where handle == handle limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) record_mail_notice(handle string, count int, now i64) ! {
	existing := sql s.db {
		select from MailNotice where handle == handle limit 1
	} or { []MailNotice{} }
	if existing.len == 0 {
		row := MailNotice{
			handle:        handle
			last_notified: now
			last_count:    count
		}
		sql s.db {
			insert row into MailNotice
		}!
	} else {
		id := existing[0].id
		sql s.db {
			update MailNotice set last_notified = now, last_count = count where id == id
		}!
	}
}
