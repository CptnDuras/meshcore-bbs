module main

import os
import time

// `meshbbs email ...`: the sysop's tools for the email groups, run from a shell. They use the database and SES directly and never open the radio, so
// they are safe to run while the daemon owns the serial port.
//
//   meshbbs email [--db sqlite:meshbbs.db] import <group> <file> [note]   add everyone in a file (one person a line); makes the group if needed
//   meshbbs email groups                                                   the groups and their sizes
//   meshbbs email members <group>                                          who is in a group, and their state
//   meshbbs email test <address>                                           send one test message through SES now
//
// The SES settings (see ses.v) are read from $MESHBBS_SES, or ~/.config/meshbbs/ses.conf.

fn ses_config_path() string {
	env := os.getenv('MESHBBS_SES')
	if env != '' {
		return env
	}
	return os.join_path(os.home_dir(), '.config', 'meshbbs', 'ses.conf')
}

// Stands in for SES when there are no settings: every attempt says what is missing.
struct NoMail {
pub:
	why string
}

fn (mut n NoMail) send(msg EmailMsg, now i64) SendResult {
	return SendResult{
		outcome: .halt
		error:   n.why
	}
}

// The sender the daemon and the tools use: real SES if the settings are there, else one that says they are not.
fn open_email_sender() EmailSender {
	path := ses_config_path()
	cfg := load_ses_config(path) or {
		return NoMail{
			why: err.msg()
		}
	}
	return Mailer{
		cfg:    cfg
		sender: &CurlSender{}
	}
}

fn open_email_worker(store Store, log fn (string)) EmailWorker {
	sender := open_email_sender()
	disabled := sender is NoMail
	if disabled {
		log('[email] no SES settings, so email is off (${(sender as NoMail).why}); mail to groups will wait in the queue')
	} else {
		log('[email] sending through SES')
	}
	return EmailWorker{
		store:    store
		sender:   sender
		disabled: disabled
		log:      log
	}
}

const email_cli_usage = 'meshbbs email [--db <db>] import <group> <file> [note] | groups | members <group> | test <address>'

// -> the text to print and the exit code. `sender` is how a test message is sent.
fn email_cli(args []string, mut store Store, mut sender EmailSender, now i64) (string, int) {
	if args.len == 0 {
		return email_cli_usage, 2
	}
	match args[0] {
		'import' {
			if args.len < 3 {
				return 'Usage: meshbbs email import <group> <file> [note]', 2
			}
			group := args[1].to_lower()
			if !valid_group_name(group) {
				return 'Group names are 2-24 letters, digits, - or _.', 2
			}
			text := os.read_file(args[2]) or { return 'Cannot read ${args[2]}', 1 }
			note := if args.len > 3 {
				args[3..].join(' ')
			} else {
				'imported from ${os.file_name(args[2])}'
			}
			list := parse_member_list(text)
			made := store.ensure_email_group(group, '', now) or { return 'Failed: ${err}', 1 }
			mut added := 0
			mut there := 0
			for p in list.people {
				if store.add_email_member(group, p.email, p.name, note, now) or { false } {
					added++
				} else {
					there++
				}
			}
			mut out := '${group}${if made { ' (new group)' } else { '' }}: ${added} added, ${there} already there'
			if list.bad.len > 0 {
				out += ', ${list.bad.len} line${if list.bad.len == 1 { '' } else { 's' }} skipped:\n' + list.bad.map('  ' + it).join('\n')
			}
			return out, 0
		}
		'groups' {
			groups := store.list_email_groups()
			if groups.len == 0 {
				return 'No email groups.', 0
			}
			mut out := ''
			for g in groups {
				ms := store.list_email_members(g.name)
				out += '${g.name}: ${ms.filter(it.status == member_active).len} active of ${ms.len}\n'
			}
			return out.trim_right('\n'), 0
		}
		'members' {
			if args.len < 2 {
				return 'Usage: meshbbs email members <group>', 2
			}
			group := args[1].to_lower()
			store.get_email_group(group) or { return 'No group ${group}.', 1 }
			mut out := ''
			for m in store.list_email_members(group) {
				out += '${m.email}\t${m.name}\t${m.status}${if m.last_error != '' {
					'\t' + m.last_error
				} else {
					''
				}}\n'
			}
			return if out == '' { 'Group ${group} is empty.' } else { out.trim_right('\n') }, 0
		}
		'test' {
			if args.len < 2 || !valid_email(normalize_email(args[1])) {
				return 'Usage: meshbbs email test <address>', 2
			}
			r := sender.send(EmailMsg{
				to:      normalize_email(args[1])
				subject: 'Test message from the mesh BBS'
				text:    'If you are reading this, the mesh BBS can send email.\n\nIt was sent from the sysop\'s shell with "meshbbs email test".\n'
			}, now)
			return match r.outcome {
				.sent { 'Sent to ${normalize_email(args[1])} (SES message ${r.message_id}).', 0 }
				.rejected { 'SES refused this address: ${r.error}', 1 }
				.retry { 'SES could not take it just now: ${r.error}', 1 }
				.halt { 'Cannot send: ${r.error}', 1 }
			}
		}
		else {
			return email_cli_usage, 2
		}
	}
}

// The real entry point: opens the database and the sender, runs the command, prints, returns the exit code.
fn email_main(raw_args []string) int {
	mut args := raw_args.clone()
	mut db := default_db
	if args.len >= 2 && args[0] == '--db' {
		db = args[1]
		args = args[2..].clone()
	}
	mut store := new_store(db) or {
		eprintln('cannot open the database ${db}: ${err}')
		return 1
	}
	store.migrate() or {}
	mut sender := open_email_sender()
	out, code := email_cli(args, mut store, mut sender, time.now().unix())
	println(out)
	return code
}
