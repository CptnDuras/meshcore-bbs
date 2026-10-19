module main

// Room navigation (Spec 11), Citadel-style: K/C/N/G.
// Read pointers are tracked per logged-in user; guests get no persistence.

// known_rooms lists rooms with unread markers: '*' unread, '-' none.
fn (mut e Engine) known_rooms(sess Session) string {
	boards := e.store.list_boards()
	if boards.len == 0 {
		return 'No rooms.'
	}
	user := e.current_user(sess) or { User{} }
	mut b := 'Known rooms:\n'
	for bd in boards {
		mut marker := '-'
		if user.id != 0 {
			if e.store.unread_count(user.id, bd.id) > 0 {
				marker = '*'
			}
		}
		b += '${marker} ${bd.name}\n'
	}
	b += 'C <room> to change, G for next unread.'
	return b
}

// change_room switches the current room (case-insensitive exact match).
fn (mut e Engine) change_room(mut sess Session, name string) string {
	if name.len == 0 {
		return 'Usage: C <room>'
	}
	board := e.store.get_board(name.trim_space()) or { return 'No such room: ${name}' }
	sess.current_board = board.id
	sess.state = state_reading
	unread := if u := e.current_user(sess) {
		e.store.unread_count(u.id, board.id)
	} else {
		0
	}
	return 'Now in ${board.name}. ${unread} unread. N to read new.'
}

// new_messages shows unread messages in the current room and advances the
// read pointer to the newest shown.
fn (mut e Engine) new_messages(mut sess Session) string {
	if !e.ensure_room(mut sess) {
		return 'No rooms yet.'
	}
	user := e.current_user(sess) or {
		return 'Log in to track new messages (or use READ <room>).'
	}
	ptr := e.store.get_last_read(user.id, sess.current_board)
	msgs := e.store.messages_after(sess.current_board, ptr, 20)
	if msgs.len == 0 {
		return 'No new messages here.'
	}
	mut b := ''
	mut newest := ptr
	for m in msgs {
		b += '#${m.id} ${m.subject} (${m.author})\n${m.body}\n---\n'
		if m.id > newest {
			newest = m.id
		}
	}
	e.store.set_last_read(user.id, sess.current_board, newest) or {}
	return b
}

// goto_next_unread moves to the next room (after current, wrapping) that has
// unread messages, and shows its new messages. Lobby if none.
fn (mut e Engine) goto_next_unread(mut sess Session) string {
	user := e.current_user(sess) or { return 'Log in to use G.' }
	boards := e.store.list_boards()
	if boards.len == 0 {
		return 'No rooms.'
	}
	// find index of current board
	mut start := 0
	for i, bd in boards {
		if bd.id == sess.current_board {
			start = i + 1
			break
		}
	}
	// scan forward, wrapping, for a room with unread
	for off in 0 .. boards.len {
		idx := (start + off) % boards.len
		bd := boards[idx]
		if e.store.unread_count(user.id, bd.id) > 0 {
			sess.current_board = bd.id
			sess.state = state_reading
			return 'Room: ${bd.name}\n' + e.new_messages(mut sess)
		}
	}
	// none: go to first room (Lobby-ish)
	sess.current_board = boards[0].id
	return 'No unread messages. Back in ${boards[0].name}.'
}

// default_room is where a user lands when they have not picked a room.
const default_room = 'general'

// ensure_room puts a session that is in no room into the default room
// (general, or the first room if general does not exist). Returns false only
// when the BBS has no rooms at all.
fn (mut e Engine) ensure_room(mut sess Session) bool {
	if sess.current_board != 0 {
		return true
	}
	b := e.store.get_board(default_room) or {
		boards := e.store.list_boards()
		if boards.len == 0 {
			return false
		}
		boards[0]
	}
	sess.current_board = b.id
	sess.state = state_reading
	return true
}

// room_by_id finds a room by id (the session stores the id of the current room).
fn (mut e Engine) room_by_id(id int) ?Board {
	for b in e.store.list_boards() {
		if b.id == id {
			return b
		}
	}
	return none
}
