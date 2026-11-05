module main

import emaillist

// Email groups: lists of people, kept by the sysop, who are sent the BBS's notices by email (a digest, an alert, a message from a sysop). Delivery is by
// Amazon SES (ses.v); the queue the daemon drains is email_outbox (email_worker.v).

// The target kind that routes an outbound or scheduled message to an email group (target = the group's name), next to target_dm and target_chan.
pub const target_email = 'email'

// A member is mailed while 'active'. 'unsubscribed' is set by the sysop at the person's request and is never undone by an import. 'rejected' is set when
// SES refuses the address (it is not verified, or it bounced); the sysop can look at it and put it back.
pub const member_active = emaillist.member_active
pub const member_unsubscribed = emaillist.member_unsubscribed
pub const member_rejected = emaillist.member_rejected

pub const email_queued = 'queued'
pub const email_sent = 'sent'
pub const email_failed = 'failed'

@[table: 'email_groups']
pub struct EmailGroup {
pub mut:
	id      int    @[primary; sql: serial]
	name    string @[unique]
	descr   string
	created i64
}

@[table: 'email_members']
pub struct EmailMember {
pub mut:
	id         int @[primary; sql: serial]
	group_name string
	email      string // lower case
	name       string // how the person likes to be addressed; may be empty
	status     string // member_active | member_unsubscribed | member_rejected
	note       string // where the consent came from, free text from the sysop ("asked at the club meeting")
	added      i64
	last_sent  i64
	last_error string
}

@[table: 'email_outbox']
pub struct EmailOutbox {
pub mut:
	id         int @[primary; sql: serial]
	to_addr    string
	subject    string
	body       string
	group_name string
	created    i64
	status     string // email_queued | email_sent | email_failed
	attempts   int
	next_try   i64 // not before this time (epoch secs)
	last_error string
	sent_ts    i64
	message_id string
	from_name  string // for a post to the list, the poster's name; '' for a notice
	list_post  bool   // sent from the list address with the list headers (see ses_request)
}

// Every message that arrived at the list address and was looked at, kept as the record of what was done with it (and so that one is never handled twice).
@[table: 'email_inbound']
pub struct EmailInbound {
pub mut:
	id         int    @[primary; sql: serial]
	s3_key     string @[unique]
	message_id string
	from_addr  string
	from_name  string
	subject    string
	received   i64
	status     string // emaillist.inbound_*
	reason     string // why it was turned away or could not be handled
	recipients int    // how many emails a post became
}

// A sender the sysop does not want posts from: an exact address ("spam@example.com") or a whole domain ("@example.com").
@[table: 'email_blocks']
pub struct EmailBlock {
pub mut:
	id      int    @[primary; sql: serial]
	pattern string @[unique]
	note    string
	added   i64
}

// A few switches (see emaillist.setting_*).
@[table: 'email_settings']
pub struct EmailSetting {
pub mut:
	id  int    @[primary; sql: serial]
	key string @[unique]
	val string
}
