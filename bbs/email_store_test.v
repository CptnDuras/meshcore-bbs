module main

import emaillist
import os

// The web UI writes to the email tables with plain SQL, using the column lists in the shared emaillist module. If the ORM models change, this fails
// until both are updated (the same arrangement as mqtt_store_test.v).
fn email_table_cols(path string, table string) []string {
	// a throwaway on-disk db so we can inspect the real ORM-created schema
	mut store := new_store('sqlite:${path}') or { panic(err) }
	store.migrate() or { panic(err) }
	mut s := store as SqliteStore
	rows := s.db.exec('PRAGMA table_info(${table})') or { panic(err) }
	mut cols := []string{}
	for r in rows {
		cols << r.vals[1]
	}
	return cols
}

fn test_orm_email_tables_match_the_shared_contract() {
	path := os.join_path(os.temp_dir(), 'email_schema_${os.getpid()}.db')
	defer {
		os.rm(path) or {}
	}
	assert email_table_cols(path, 'email_groups') == emaillist.groups_columns
	assert email_table_cols(path, 'email_members') == emaillist.members_columns
	assert email_table_cols(path, 'email_outbox') == emaillist.outbox_columns
	assert email_table_cols(path, 'email_inbound') == emaillist.inbound_columns
	assert email_table_cols(path, 'email_blocks') == emaillist.blocks_columns
	assert email_table_cols(path, 'email_settings') == emaillist.settings_columns
}

// A database made before posting by email existed has an outbox without the two new columns; migrating adds them at the end, so it ends up exactly like
// a new one, and what was queued is kept.
fn test_an_old_outbox_gains_the_new_columns_and_keeps_its_rows() {
	path := os.join_path(os.temp_dir(), 'email_old_${os.getpid()}.db')
	defer {
		os.rm(path) or {}
	}
	mut store := new_store('sqlite:${path}') or { panic(err) }
	store.migrate() or { panic(err) }
	mut s := store as SqliteStore
	s.db.exec('DROP TABLE email_outbox') or { panic(err) }
	s.db.exec('CREATE TABLE email_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, to_addr TEXT NOT NULL, subject TEXT NOT NULL, body TEXT NOT NULL, group_name TEXT NOT NULL, created INTEGER NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL, next_try INTEGER NOT NULL, last_error TEXT NOT NULL, sent_ts INTEGER NOT NULL, message_id TEXT NOT NULL)') or {
		panic(err)
	}
	s.db.exec("INSERT INTO email_outbox (to_addr, subject, body, group_name, created, status, attempts, next_try, last_error, sent_ts, message_id) VALUES ('a@example.com', 's', 'b', 'g', 1, 'queued', 0, 0, '', 0, '')") or {
		panic(err)
	}
	store.migrate() or { panic(err) }
	assert email_table_cols(path, 'email_outbox') == emaillist.outbox_columns
	due := store.due_emails(100, 5)
	assert due.len == 1 && due[0].to_addr == 'a@example.com' && due[0].list_post == false && due[0].from_name == ''
}

fn test_the_daemons_member_states_are_the_shared_ones() {
	assert member_active == emaillist.member_active
	assert member_unsubscribed == emaillist.member_unsubscribed
	assert member_rejected == emaillist.member_rejected
}
