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
}

fn test_the_daemons_member_states_are_the_shared_ones() {
	assert member_active == emaillist.member_active
	assert member_unsubscribed == emaillist.member_unsubscribed
	assert member_rejected == emaillist.member_rejected
}
