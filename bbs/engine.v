module main

import crypto.bcrypt
import time

// Engine ties the Store to the session/command logic. The main loop calls
// handle() with the sender's pubkey prefix and their message text, and gets
// back the reply text (which the loop paginates and sends over the mesh).
pub struct Engine {
pub mut:
	store Store
	name  string = 'meshbbs'
	// started is the epoch-secs the engine was created; powers STATS uptime.
	started i64
	// rate limiting (mesh self-defense): minimum seconds between handled turns
	// from the same node. 0 disables. last_turn tracks each node's last accepted
	// turn time (epoch secs). See rate_limit.v.
	min_turn_interval i64
	last_turn         map[string]i64
	// public-channel slash command limits (see chancmd.v)
	chan_cmd_last   map[string]i64
	chan_cmd_recent []i64
	// help is injected so the wording or lookup can be swapped (see help.v)
	help HelpRenderer = default_help_renderer()
	// help_file is the config file HELPRELOAD/HELPIMPORT read (see help_catalog.v)
	help_file string = 'help.txt'
	// commands is the set of BBS commands; injected so tests can register only
	// the feature under test (see commands.v)
	commands CommandSource = standard_commands()
}

// is_sysop reports whether the session's user is a sysop.
fn (mut e Engine) is_sysop(sess Session) bool {
	u := e.current_user(sess) or { return false }
	return perm_from_int(u.perm) == Perm.sysop
}

// handle processes one inbound line from a node and returns reply text.
pub fn (mut e Engine) handle(pubkey_prefix string, raw string) string {
	line := raw.trim_space()
	// load or create the session
	mut sess := e.store.load_session(pubkey_prefix) or {
		Session{
			pubkey_prefix: pubkey_prefix
			state:         state_guest
			handle:        ''
		}
	}

	// Auto-register: every node gets a user-level account on first contact
	// (mandatory registration retired). If this session isn't attached to a
	// handle yet, attach it to the node's auto-account (creating it if needed).
	// A user who later CLAIMs a real handle logs in via LOGIN instead.
	if sess.handle.len == 0 {
		if u := e.store.get_or_create_node_user(pubkey_prefix) {
			sess.handle = u.handle
			if sess.state == state_guest {
				sess.state = state_main
			}
		}
	}

	// Rate limiting (mesh self-defense): throttle nodes that send too fast.
	// A throttled turn is still audited (as '(throttled)') but does no command
	// work and returns a terse notice, saving airtime and DB writes.
	now := time.now().unix()
	if !e.check_rate_limit(pubkey_prefix, now) {
		e.store.log_interaction(pubkey_prefix, sess.handle, '(throttled)', raw, 0) or {}
		return 'Slow down — one message every ${e.min_turn_interval}s please.'
	}

	// If mid message-entry, route the raw line to the accumulator (bypasses
	// command parsing) so message text isn't interpreted as commands.
	was_entry := e.in_entry(sess)
	reply := if was_entry {
		e.handle_entry_line(mut sess, raw)
	} else {
		e.dispatch(mut sess, line)
	}

	// persist session after handling
	e.store.save_session(sess) or {}

	// One-time friendly greeting on a node's very first contact, prepended to
	// their first reply so newcomers understand the system without reading docs.
	mut final_reply := reply
	if !sess.greeted {
		final_reply = e.greeting(sess) + '\n\n' + reply
		sess.greeted = true
		e.store.save_session(sess) or {}
	}

	// Durable audit log of this turn. Internal/sysop-only: nothing in the
	// command dispatch can read this back, so BBS callers never see it.
	// Best-effort — a logging failure must not break the caller's reply.
	cmd_token := if was_entry { '(entry)' } else { interaction_command(line) }
	e.store.log_interaction(pubkey_prefix, sess.handle, cmd_token, raw, final_reply.len) or {}

	return final_reply
}

// greeting is the one-time welcome shown on a node's first contact. It explains
// the auto-register model and points at HELP and /config in a friendly, terse
// way suited to the mesh.
fn (e Engine) greeting(sess Session) string {
	return e.help.welcome(e.name, display_name(sess.handle))
}

// help_viewer describes the asker to the help system (permission + newness).
fn (mut e Engine) help_viewer(sess Session) SessionViewer {
	u := e.current_user(sess) or { User{} }
	return SessionViewer{
		level: perm_from_int(u.perm)
		fresh: !sess.greeted
	}
}

// interaction_command extracts the leading command token (upper-cased) from an
// already-trimmed line, for the audit log. Empty line -> '(menu)'.
fn interaction_command(line string) string {
	if line.len == 0 {
		return '(menu)'
	}
	return line.split(' ')[0].to_upper()
}

// log_slash records a hidden slash command (e.g. /advert) in the audit log.
// Hidden commands are handled outside dispatch (in main.v where the radio is
// reachable), so they would otherwise bypass the interaction audit trail.
pub fn (mut e Engine) log_slash(pubkey_prefix string, command string, detail string) {
	e.store.log_interaction(pubkey_prefix, '', command, detail, 0) or {}
}

// log_traffic records a passive mesh-traffic observation (best-effort).
pub fn (mut e Engine) log_traffic(kind string, pubkey_prefix string, snr f64, path_len int) {
	e.store.log_traffic(kind, pubkey_prefix, snr, path_len) or {}
}

// save_node_name upserts a pubkey_prefix -> friendly-name mapping (best-effort).
pub fn (mut e Engine) save_node_name(pubkey_prefix string, name string, contact_type int, last_advert i64) {
	if pubkey_prefix.len == 0 {
		return
	}
	e.store.upsert_node_name(pubkey_prefix, name, contact_type, last_advert) or {}
}

// resolve_node_name returns the friendly name for a prefix, or '' if unknown.
pub fn (mut e Engine) resolve_node_name(pubkey_prefix string) string {
	n := e.store.get_node_name(pubkey_prefix) or { return '' }
	return n.name
}

fn (mut e Engine) dispatch(mut sess Session, line string) string {
	if line.len == 0 {
		return e.menu(sess)
	}
	parts := line.split(' ')
	cmd := parts[0].to_upper()
	args := if parts.len > 1 { parts[1..].join(' ') } else { '' }

	// Special-case NEW: "NEW <handle> <pass>" names/claims the account (retro
	// Citadel style); bare "N"/"NEW" means new-messages. With auto-register the
	// session always has a handle, so disambiguate on whether it's still an
	// unclaimed node handle (user hasn't named themselves) + argument presence.
	if cmd == 'NEW' && args.len > 0 && is_node_handle(sess.handle) {
		return e.register(mut sess, args)
	}

	// A bare digit is a pick from the help menu ("1" == "HELP 1").
	if args.len == 0 {
		if text := e.help.topic_for_digit(cmd, e.help_viewer(sess)) {
			return text
		}
	}

	// every command is a registered function (see commands.v and cmd_*.v)
	if c := e.commands.find(cmd) {
		return c.handler(mut e, mut sess, args)
	}
	return e.handle_unknown(mut sess, cmd, args)
}

// handle_unknown is the fallback for an unrecognized command. It first tries a
// user-defined macro (see /CONFIG custom commands); otherwise it returns a
// friendly hint, suggesting the closest built-in command when one is close.
fn (mut e Engine) handle_unknown(mut sess Session, cmd string, args string) string {
	// user custom macro? (text-macro commands defined via /CONFIG)
	if macro := e.lookup_macro(sess, cmd) {
		return macro
	}
	if sug := suggest_command(cmd, e.command_names()) {
		return 'Unknown command "${cmd}". Did you mean ${sug}? Send HELP for the full list.'
	}
	return 'Unknown command "${cmd}". Send HELP for commands, or MENU to get oriented.'
}

// command_names lists the primary name of every registered command, for
// "did you mean" suggestions.
fn (e Engine) command_names() []string {
	return e.commands.all().map(it.names[0])
}

// suggest_command returns the closest of `names` to `cmd` if one is within a
// small edit distance (a simple typo helper), else none.
fn suggest_command(cmd string, names []string) ?string {
	mut best := ''
	mut best_d := 3 // only suggest when reasonably close
	for k in names {
		d := edit_distance(cmd, k)
		if d < best_d {
			best_d = d
			best = k
		}
	}
	if best.len == 0 {
		return none
	}
	return best
}

// edit_distance is a small Levenshtein implementation for typo suggestions.
fn edit_distance(a string, b string) int {
	if a.len == 0 {
		return b.len
	}
	if b.len == 0 {
		return a.len
	}
	mut prev := []int{len: b.len + 1, init: index}
	mut cur := []int{len: b.len + 1, init: 0}
	for i := 1; i <= a.len; i++ {
		cur[0] = i
		for j := 1; j <= b.len; j++ {
			cost := if a[i - 1] == b[j - 1] { 0 } else { 1 }
			mut m := prev[j] + 1
			if cur[j - 1] + 1 < m {
				m = cur[j - 1] + 1
			}
			if prev[j - 1] + cost < m {
				m = prev[j - 1] + cost
			}
			cur[j] = m
		}
		for k in 0 .. b.len + 1 {
			prev[k] = cur[k]
		}
	}
	return prev[b.len]
}

fn (e Engine) is_user(sess Session) bool {
	return sess.handle.len > 0
}

// current_user loads the logged-in user's record, or none if guest.
fn (mut e Engine) current_user(sess Session) ?User {
	if sess.handle.len == 0 {
		return none
	}
	return e.store.get_user(sess.handle)
}

// is_node_handle reports whether a handle is an unclaimed auto-handle
// (node-<pubkey_prefix>) vs a real handle the user chose via CLAIM/NEW.
fn is_node_handle(handle string) bool {
	return handle.starts_with('node-')
}

// display_name is what we show the user for their identity: a claimed handle as
// itself, or a friendly short tag for an unclaimed auto-account.
fn display_name(handle string) string {
	if is_node_handle(handle) {
		// node-4b81424f7106 -> guest-4b81 (short, friendly)
		suffix := handle['node-'.len..]
		short := if suffix.len > 4 { suffix[..4] } else { suffix }
		return 'guest-${short}'
	}
	return handle
}

fn (e Engine) menu(sess Session) string {
	name := display_name(sess.handle)
	mut b := '== ${e.name} ==\nHi ${name}!\n'
	b += 'Read:  [L]ist boards · [R]ead <board> · [N]ew msgs\n'
	b += 'Post:  [P]ost <board>|<subject>|<body>\n'
	b += 'Info:  WX · FORECAST [days] · NEWS · WHO · STATS\n'
	b += 'You:   /CONFIG (preferences + custom cmds)\n'
	if is_node_handle(sess.handle) {
		b += 'Tip:   CLAIM <handle> <pass> to name your account (log in from other devices).\n'
	}
	b += 'HELP = guided help (reply with a number).'
	return b
}

fn (mut e Engine) help_reply(sess Session, args string) string {
	return e.help.render(args, e.help_viewer(sess))
}

fn (mut e Engine) who() string {
	// v1: report boards + a placeholder; a real WHO would query recent nodes.
	boards := e.store.list_boards()
	return 'Node: ${e.name}\nBoards: ${boards.len}\n(WHO node-tracking coming soon)'
}

fn (mut e Engine) list_boards() string {
	boards := e.store.list_boards()
	if boards.len == 0 {
		return 'No boards yet.'
	}
	mut b := 'Boards:\n'
	for bd in boards {
		b += '- ${bd.name}: ${bd.descr}\n'
	}
	b += 'READ <board> to read.'
	return b
}

fn (mut e Engine) read_board(mut sess Session, name string) string {
	// R alone reads the room you are in (general until you pick another)
	if name.trim_space().len == 0 && !e.ensure_room(mut sess) {
		return 'No rooms yet.'
	}
	board := if name.trim_space().len == 0 {
		e.room_by_id(sess.current_board) or { return 'No such room. K lists the rooms.' }
	} else {
		e.store.get_board(name.trim_space()) or { return 'No such room: ${name}. K lists the rooms.' }
	}
	msgs := e.store.board_messages(board.id, 20)
	sess.state = state_reading
	sess.current_board = board.id
	if msgs.len == 0 {
		return 'Board "${board.name}" is empty.'
	}
	mut b := '== ${board.name} ==\n'
	for m in msgs {
		b += '#${m.id} ${m.subject} (by ${m.author})\n${m.body}\n---\n'
	}
	return b
}

fn (mut e Engine) register(mut sess Session, args string) string {
	p := args.split(' ')
	if p.len < 2 {
		return 'Usage: NEW <handle> <password>'
	}
	handle := p[0]
	pass := p[1..].join(' ')
	if is_node_handle(handle) || handle.len < 2 {
		return 'Pick a different handle (2+ chars, not starting with "node-").'
	}
	if _ := e.store.get_user(handle) {
		return 'Handle "${handle}" is taken.'
	}
	hash := bcrypt.generate_from_password(pass.bytes(), bcrypt.default_cost) or {
		return 'Registration failed (hash error).'
	}
	// With auto-register, the caller already has an account. NEW names it
	// (claim): rename the node account + set a password, keeping its perm level
	// (so the bootstrap sysop stays sysop). Falls back to creating a fresh
	// account if somehow unattached.
	cur := e.current_user(sess) or {
		created := e.store.create_user(handle, hash) or { return 'Registration failed: ${err}' }
		sess.handle = handle
		sess.state = state_main
		return 'Welcome, ${handle}! Registered (level ${perm_from_int(created.perm).str_name()}). MENU for options.'
	}
	if !is_node_handle(cur.handle) {
		return 'You already have a handle (${cur.handle}). Use SETPASS to change your password.'
	}
	e.store.claim_handle(cur.handle, handle, hash) or { return 'Registration failed: ${err}' }
	sess.handle = handle
	sess.state = state_main
	return 'Welcome, ${handle}! Your account is now named ${handle} (level ${perm_from_int(cur.perm).str_name()}). Log in from any device with LOGIN ${handle} <password>.'
}

// claim converts the caller's auto-registered node account into a named account
// with a password, so they can LOGIN from another device. No multi-pubkey
// linking: this simply renames the existing account and sets a password.
fn (mut e Engine) claim(mut sess Session, args string) string {
	p := args.split(' ')
	if p.len < 2 {
		return 'Usage: CLAIM <handle> <password> — names your account so you can log in from other devices.'
	}
	user := e.current_user(sess) or { return 'No account to claim.' }
	if !is_node_handle(user.handle) {
		return 'You already have a handle (${user.handle}). Use SETPASS to change your password.'
	}
	new_handle := p[0]
	pass := p[1..].join(' ')
	if is_node_handle(new_handle) || new_handle.len < 2 {
		return 'Pick a different handle (2+ chars, not starting with "node-").'
	}
	hash := bcrypt.generate_from_password(pass.bytes(), bcrypt.default_cost) or {
		return 'Claim failed (hash error).'
	}
	e.store.claim_handle(user.handle, new_handle, hash) or { return 'Claim failed: ${err}' }
	sess.handle = new_handle
	return 'Claimed! Your handle is now ${new_handle}. LOGIN ${new_handle} <password> from any device.'
}

// set_pass sets or changes the password on the caller's account. Requires a
// claimed handle (an unclaimed node account should CLAIM first to get a name).
fn (mut e Engine) set_pass(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'No account.' }
	if is_node_handle(user.handle) {
		return 'CLAIM a handle first: CLAIM <handle> <password>.'
	}
	pass := args.trim_space()
	if pass.len < 1 {
		return 'Usage: SETPASS <new password>'
	}
	hash := bcrypt.generate_from_password(pass.bytes(), bcrypt.default_cost) or {
		return 'Failed (hash error).'
	}
	e.store.set_user_pass(user.handle, hash) or { return 'Failed: ${err}' }
	return 'Password updated.'
}

fn (mut e Engine) login(mut sess Session, args string) string {
	p := args.split(' ')
	if p.len < 2 {
		return 'Usage: LOGIN <handle> <password>'
	}
	handle := p[0]
	pass := p[1..].join(' ')
	user := e.store.get_user(handle) or { return 'Login failed.' }
	if user.banned {
		return 'Your account is banned.'
	}
	bcrypt.compare_hash_and_password(pass.bytes(), user.pass_hash.bytes()) or {
		return 'Login failed.'
	}
	sess.handle = handle
	sess.state = state_main
	e.store.touch_user_seen(handle) or {}
	return 'Welcome back, ${handle}! MENU for options.' + e.mail_notice(handle)
}

fn (mut e Engine) logout(mut sess Session) string {
	sess.handle = ''
	sess.state = state_guest
	sess.current_board = 0
	return 'Logged out. Thanks for calling. NO CARRIER.'
}

fn (mut e Engine) post(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN to post.' }
	if user.banned {
		return 'Your account is banned.'
	}
	if !has_permission(user, 'post') {
		return 'You are not verified yet. A sysop must verify you before you can post.'
	}
	// format: <board>|<subject>|<body>
	parts := args.split('|')
	if parts.len < 3 {
		return 'Usage: POST <board>|<subject>|<body>'
	}
	board := e.store.get_board(parts[0].trim_space()) or { return 'No such board: ${parts[0]}' }
	e.store.post_message(board.id, sess.handle, parts[1].trim_space(), parts[2].trim_space(),
		0) or { return 'Post failed: ${err}' }
	return 'Posted to ${board.name}.'
}

// --- moderation / sysop-aide commands (Spec 10/14) ---

fn (mut e Engine) verify_user(mut sess Session, target string) string {
	actor := e.current_user(sess) or { return 'You must LOGIN.' }
	if !has_permission(actor, 'verify_user') {
		return 'Permission denied (AIDE+ required).'
	}
	tgt := e.store.get_user(target) or { return 'No such user: ${target}' }
	if perm_from_int(tgt.perm) != Perm.unverified {
		return '${target} is already verified.'
	}
	e.store.set_user_perm(target, int(Perm.user)) or { return 'Verify failed: ${err}' }
	return 'Verified ${target} -> user.'
}

fn (mut e Engine) set_perm_cmd(mut sess Session, args string, level Perm) string {
	actor := e.current_user(sess) or { return 'You must LOGIN.' }
	if !has_permission(actor, 'set_perm') {
		return 'Permission denied (AIDE+ required).'
	}
	target := args.trim_space()
	if target.len == 0 {
		return 'Usage: <cmd> <handle>'
	}
	if !can_set_perm(actor, level) {
		return 'You cannot set a permission at or above your own level.'
	}
	e.store.get_user(target) or { return 'No such user: ${target}' }
	e.store.set_user_perm(target, int(level)) or { return 'Failed: ${err}' }
	return 'Set ${target} -> ${level.str_name()}.'
}

fn (mut e Engine) ban_user(mut sess Session, target string, banned bool) string {
	actor := e.current_user(sess) or { return 'You must LOGIN.' }
	if !has_permission(actor, 'ban_user') {
		return 'Permission denied (AIDE+ required).'
	}
	e.store.get_user(target.trim_space()) or { return 'No such user: ${target}' }
	e.store.set_user_banned(target.trim_space(), banned) or { return 'Failed: ${err}' }
	return if banned { 'Banned ${target}.' } else { 'Unbanned ${target}.' }
}

fn (mut e Engine) delete_message(mut sess Session, args string) string {
	actor := e.current_user(sess) or { return 'You must LOGIN.' }
	if !has_permission(actor, 'delete_message') {
		return 'Permission denied (AIDE+ required).'
	}
	id := args.trim_space().int()
	if id <= 0 {
		return 'Usage: DELETE <message-id>'
	}
	e.store.delete_message(id) or { return 'Delete failed: ${err}' }
	return 'Deleted message #${id}.'
}
