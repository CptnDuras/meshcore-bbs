module main

import emaillist

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

// ---- posts to the list ----

pub fn (mut s SqliteStore) enqueue_post_email(to_addr string, subject string, body string, group string, from_name string, now i64) ! {
	row := EmailOutbox{
		to_addr:    to_addr
		subject:    subject
		body:       body
		group_name: group
		created:    now
		status:     email_queued
		next_try:   now
		from_name:  from_name
		list_post:  true
	}
	sql s.db {
		insert row into EmailOutbox
	}!
}

// -> false if this message was already seen (so it is not handled twice)
pub fn (mut s SqliteStore) inbound_begin(s3_key string, now i64) !bool {
	if s.inbound_status(s3_key) != '' {
		return false
	}
	row := EmailInbound{
		s3_key:   s3_key
		received: now
		status:   emaillist.inbound_posting
	}
	sql s.db {
		insert row into EmailInbound
	}!
	return true
}

pub fn (mut s SqliteStore) inbound_finish(s3_key string, mail_id string, from_addr string, from_name string, subject string, status string, reason string, recipients int) ! {
	sql s.db {
		update EmailInbound set message_id = mail_id, from_addr = from_addr, from_name = from_name, subject = subject, status = status, reason = reason, recipients = recipients where s3_key == s3_key
	}!
}

pub fn (mut s SqliteStore) inbound_status(s3_key string) string {
	rows := sql s.db {
		select from EmailInbound where s3_key == s3_key limit 1
	} or { []EmailInbound{} }
	return if rows.len > 0 { rows[0].status } else { '' }
}

pub fn (mut s SqliteStore) count_inbound(status string, since i64) int {
	return sql s.db {
		select count from EmailInbound where status == status && received >= since
	} or { 0 }
}

// posts passed on to the list from one sender since a time
pub fn (mut s SqliteStore) count_posts_by(from_addr string, since i64) int {
	posted := emaillist.inbound_posted
	return sql s.db {
		select count from EmailInbound where from_addr == from_addr && status == posted && received >= since
	} or { 0 }
}

pub fn (mut s SqliteStore) recent_inbound(limit int) []EmailInbound {
	return sql s.db {
		select from EmailInbound order by id desc limit limit
	} or { []EmailInbound{} }
}

// the record of old messages is kept 90 days
pub fn (mut s SqliteStore) prune_inbound(before i64) ! {
	sql s.db {
		delete from EmailInbound where received < before
	}!
}

pub fn (mut s SqliteStore) add_email_block(pattern string, note string, now i64) !bool {
	existing := sql s.db {
		select from EmailBlock where pattern == pattern limit 1
	} or { []EmailBlock{} }
	if existing.len > 0 {
		return false
	}
	row := EmailBlock{
		pattern: pattern
		note:    note
		added:   now
	}
	sql s.db {
		insert row into EmailBlock
	}!
	return true
}

pub fn (mut s SqliteStore) remove_email_block(pattern string) ! {
	sql s.db {
		delete from EmailBlock where pattern == pattern
	}!
}

pub fn (mut s SqliteStore) list_email_blocks() []EmailBlock {
	return sql s.db {
		select from EmailBlock order by pattern
	} or { []EmailBlock{} }
}

// An address is blocked by its own entry or by an entry for its domain ("@example.com").
pub fn (mut s SqliteStore) is_blocked_sender(addr string) bool {
	a := addr.to_lower()
	domain := '@' + a.all_after('@')
	for b in s.list_email_blocks() {
		if b.pattern == a || b.pattern == domain {
			return true
		}
	}
	return false
}

pub fn (mut s SqliteStore) get_email_setting(key string) string {
	rows := sql s.db {
		select from EmailSetting where key == key limit 1
	} or { []EmailSetting{} }
	return if rows.len > 0 { rows[0].val } else { '' }
}

pub fn (mut s SqliteStore) set_email_setting(key string, val string) ! {
	rows := sql s.db {
		select from EmailSetting where key == key limit 1
	} or { []EmailSetting{} }
	if rows.len == 0 {
		row := EmailSetting{
			key: key
			val: val
		}
		sql s.db {
			insert row into EmailSetting
		}!
	} else {
		sql s.db {
			update EmailSetting set val = val where key == key
		}!
	}
}
