module main

// The email groups' part of the SQLite store (the Store interface lists these in store.v).

pub fn (mut s SqliteStore) ensure_email_group(name string, descr string, now i64) !bool {
	existing := sql s.db {
		select from EmailGroup where name == name limit 1
	} or { []EmailGroup{} }
	if existing.len > 0 {
		return false
	}
	row := EmailGroup{
		name:    name
		descr:   descr
		created: now
	}
	sql s.db {
		insert row into EmailGroup
	}!
	return true
}

pub fn (mut s SqliteStore) list_email_groups() []EmailGroup {
	return sql s.db {
		select from EmailGroup order by name
	} or { []EmailGroup{} }
}

pub fn (mut s SqliteStore) get_email_group(name string) ?EmailGroup {
	rows := sql s.db {
		select from EmailGroup where name == name limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) delete_email_group(name string) ! {
	sql s.db {
		delete from EmailMember where group_name == name
	}!
	sql s.db {
		delete from EmailGroup where name == name
	}!
}

// -> true if the person was added, false if they were already in the group (nothing is changed: an unsubscribed person stays unsubscribed)
pub fn (mut s SqliteStore) add_email_member(group string, email string, name string, note string, now i64) !bool {
	if _ := s.get_email_member(group, email) {
		return false
	}
	row := EmailMember{
		group_name: group
		email:      email
		name:       name
		status:     member_active
		note:       note
		added:      now
	}
	sql s.db {
		insert row into EmailMember
	}!
	return true
}

pub fn (mut s SqliteStore) get_email_member(group string, email string) ?EmailMember {
	rows := sql s.db {
		select from EmailMember where group_name == group && email == email limit 1
	} or { return none }
	if rows.len == 0 {
		return none
	}
	return rows[0]
}

pub fn (mut s SqliteStore) list_email_members(group string) []EmailMember {
	return sql s.db {
		select from EmailMember where group_name == group order by email
	} or { []EmailMember{} }
}

pub fn (mut s SqliteStore) set_email_member_status(group string, email string, status string, err_text string) ! {
	sql s.db {
		update EmailMember set status = status, last_error = err_text where group_name == group && email == email
	}!
}

pub fn (mut s SqliteStore) touch_email_member_sent(email string, now i64) ! {
	sql s.db {
		update EmailMember set last_sent = now where email == email
	}!
}

pub fn (mut s SqliteStore) remove_email_member(group string, email string) ! {
	sql s.db {
		delete from EmailMember where group_name == group && email == email
	}!
}

// ---- the queue ----

pub fn (mut s SqliteStore) enqueue_email(to_addr string, subject string, body string, group string, now i64) ! {
	row := EmailOutbox{
		to_addr:    to_addr
		subject:    subject
		body:       body
		group_name: group
		created:    now
		status:     email_queued
		next_try:   now
	}
	sql s.db {
		insert row into EmailOutbox
	}!
}

pub fn (mut s SqliteStore) due_emails(now i64, limit int) []EmailOutbox {
	queued := email_queued
	return sql s.db {
		select from EmailOutbox where status == queued && next_try <= now order by id limit limit
	} or { []EmailOutbox{} }
}

pub fn (mut s SqliteStore) mark_email_sent(id int, message_id string, now i64) ! {
	sent := email_sent
	empty := ''
	sql s.db {
		update EmailOutbox set status = sent, sent_ts = now, message_id = message_id, last_error = empty where id == id
	}!
}

pub fn (mut s SqliteStore) mark_email_failed(id int, err_text string) ! {
	failed := email_failed
	sql s.db {
		update EmailOutbox set status = failed, last_error = err_text where id == id
	}!
}

// kept in the queue, to be tried again at next_try
pub fn (mut s SqliteStore) retry_email_later(id int, err_text string, next_try i64) ! {
	rows := sql s.db {
		select from EmailOutbox where id == id limit 1
	} or { []EmailOutbox{} }
	if rows.len == 0 {
		return
	}
	attempts := rows[0].attempts + 1
	sql s.db {
		update EmailOutbox set attempts = attempts, next_try = next_try, last_error = err_text where id == id
	}!
}

pub fn (mut s SqliteStore) count_emails(status string) int {
	return sql s.db {
		select count from EmailOutbox where status == status
	} or { 0 }
}

pub fn (mut s SqliteStore) count_emails_sent_since(since i64) int {
	sent := email_sent
	return sql s.db {
		select count from EmailOutbox where status == sent && sent_ts >= since
	} or { 0 }
}

pub fn (mut s SqliteStore) recent_failed_emails(limit int) []EmailOutbox {
	failed := email_failed
	return sql s.db {
		select from EmailOutbox where status == failed order by id desc limit limit
	} or { []EmailOutbox{} }
}

// Cleans up: sent and failed messages older than `before` are removed (the queue is not an archive).
pub fn (mut s SqliteStore) prune_emails(before i64) ! {
	queued := email_queued
	sql s.db {
		delete from EmailOutbox where status != queued && created < before
	}!
}
