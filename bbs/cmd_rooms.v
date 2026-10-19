module main

// Rooms (boards) and posting.

fn register_room_commands(mut r CommandRegistry) {
	r.add(['KNOWN', 'K'], cmd_known)
	r.add(['CHANGE', 'C'], cmd_change)
	r.add(['NEW', 'N'], cmd_new)
	r.add(['GOTO', 'G'], cmd_goto)
	r.add(['READ', 'R'], cmd_read)
	r.add(['ENTER', 'E'], cmd_enter)
	r.add(['LIST', 'L'], cmd_list)
	r.add(['POST', 'P'], cmd_post)
}

fn cmd_known(mut e Engine, mut sess Session, args string) string {
	return e.known_rooms(sess)
}

fn cmd_change(mut e Engine, mut sess Session, args string) string {
	return e.change_room(mut sess, args)
}

fn cmd_new(mut e Engine, mut sess Session, args string) string {
	return e.new_messages(mut sess)
}

fn cmd_goto(mut e Engine, mut sess Session, args string) string {
	return e.goto_next_unread(mut sess)
}

fn cmd_read(mut e Engine, mut sess Session, args string) string {
	return e.read_board(mut sess, args)
}

fn cmd_enter(mut e Engine, mut sess Session, args string) string {
	return e.start_entry(mut sess, args)
}

fn cmd_list(mut e Engine, mut sess Session, args string) string {
	return e.list_boards()
}

fn cmd_post(mut e Engine, mut sess Session, args string) string {
	return e.post(mut sess, args)
}
