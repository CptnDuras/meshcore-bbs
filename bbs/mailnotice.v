module main

// Proactive mail-notice rate limiting (store-and-forward "you have mail").
//
// When the daemon hears an advert from a node whose BBS account has unread
// mail, it may send a single terse notice via the outbound queue. To avoid
// spamming a node that advertises frequently, we guard with a decision that
// only re-notifies when there is genuinely new mail or a cooldown has elapsed.

const mail_notice_cooldown = i64(6 * 60 * 60) // 6h between repeat notices

// should_notify_mail is a pure decision: given the current unread count, the
// last time we notified this handle, and the unread count at that time, decide
// whether to send a notice now. Notify when:
//   - there is unread mail, AND
//   - we've never notified (last_notified == 0), OR
//   - the unread count has grown since last notice (new mail arrived), OR
//   - the cooldown has elapsed since the last notice.
fn should_notify_mail(unread int, last_notified i64, last_count int, now i64) bool {
	if unread <= 0 {
		return false
	}
	if last_notified <= 0 {
		return true
	}
	if unread > last_count {
		return true
	}
	return (now - last_notified) >= mail_notice_cooldown
}

// maybe_mail_notice decides whether to notify `handle` about unread mail right
// now, consulting + updating the store guard. Returns the notice text to send,
// or '' if no notice is due. Records the notice when it returns non-empty.
fn (mut e Engine) maybe_mail_notice(handle string, now i64) string {
	if handle.len == 0 {
		return ''
	}
	unread := e.store.unread_mail_count(handle)
	if unread <= 0 {
		return ''
	}
	mut last_notified := i64(0)
	mut last_count := 0
	if g := e.store.get_mail_notice(handle) {
		last_notified = g.last_notified
		last_count = g.last_count
	}
	if !should_notify_mail(unread, last_notified, last_count, now) {
		return ''
	}
	e.store.record_mail_notice(handle, unread, now) or {}
	return 'You have ${unread} new mail on ${e.name}. Send MAILBOX to read.'
}
