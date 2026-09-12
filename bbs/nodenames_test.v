module main

import time

fn nn_store() Store {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	return store
}

// --- node names ---

fn test_node_name_upsert_and_get() {
	mut s := nn_store()
	s.upsert_node_name('4b81424f7106', 'XeroKuhl', 1, 12345) or { panic(err) }
	n := s.get_node_name('4b81424f7106') or { panic('should exist') }
	assert n.name == 'XeroKuhl'
	assert n.contact_type == 1
	assert n.last_advert == 12345
}

fn test_node_name_upsert_updates_existing() {
	mut s := nn_store()
	s.upsert_node_name('aa', 'OldName', 1, 100) or { panic(err) }
	s.upsert_node_name('aa', 'NewName', 2, 200) or { panic(err) }
	// still one row, updated in place
	assert s.count_node_names() == 1
	n := s.get_node_name('aa') or { panic('should exist') }
	assert n.name == 'NewName'
	assert n.contact_type == 2
	assert n.last_advert == 200
}

fn test_node_name_missing() {
	mut s := nn_store()
	if _ := s.get_node_name('nope') {
		assert false, 'should not find missing node'
	}
	assert true
}

fn test_node_name_list() {
	mut s := nn_store()
	s.upsert_node_name('a1', 'Orion', 1, 0) or {}
	s.upsert_node_name('a2', 'XeroKuhl', 1, 0) or {}
	names := s.list_node_names(10)
	assert names.len == 2
}

// --- mesh traffic ---

fn test_traffic_log_and_count() {
	mut s := nn_store()
	s.log_traffic('advert', 'aa', 5.5, 0) or { panic(err) }
	s.log_traffic('chan_msg', 'bb', -2.25, 3) or { panic(err) }
	assert s.count_traffic() == 2
	rows := s.recent_traffic(10)
	assert rows.len == 2
	// most recent first
	assert rows[0].kind == 'chan_msg'
	assert rows[0].snr == -2.25
	assert rows[0].path_len == 3
}

fn test_traffic_distinct_nodes_since() {
	mut s := nn_store()
	s.log_traffic('advert', 'aa', 0, 0) or {}
	s.log_traffic('advert', 'aa', 0, 0) or {}
	s.log_traffic('advert', 'bb', 0, 0) or {}
	s.log_traffic('path', '', 0, 0) or {} // empty source ignored
	now := time.now().unix()
	assert s.traffic_nodes_since(now - 3600) == 2
}
