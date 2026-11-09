module main

// a flood packet (route type 1) with path_len = hops | (size-1)<<6, the path, then a payload
fn pkt(route_type u8, size int, names []u8) []u8 {
	mut b := [u8(route_type)]
	if route_type == 0 || route_type == 3 {
		b << [u8(1), 2, 3, 4]
	}
	b << u8(names.len / size) | u8((size - 1) << 6)
	b << names
	b << [u8(0xAA), 0xBB] // payload
	return b
}

fn test_heard_path_one_byte_names() {
	hp := heard_path(pkt(1, 1, [u8(0x11), 0x22, 0x33]))?
	assert hp.names == ['11', '22', '33']
}

fn test_heard_path_two_byte_names() {
	hp := heard_path(pkt(1, 2, [u8(0x11), 0x22, 0x33, 0x44]))?
	assert hp.names == ['1122', '3344']
}

fn test_heard_path_skips_transport_codes() {
	hp := heard_path(pkt(0, 1, [u8(0x11), 0x22]))?
	assert hp.names == ['11', '22']
	assert (heard_path(pkt(3, 1, [u8(0x11)]))?).names == ['11']
}

fn test_heard_path_empty_path_is_fine() {
	hp := heard_path(pkt(1, 1, []u8{}))?
	assert hp.names.len == 0
}

fn test_heard_path_rejects_junk() {
	assert heard_path([]u8{}) == none
	assert heard_path([u8(1), 2]) == none
	// says 3 names but the packet ends first
	assert heard_path([u8(1), 3, 0x11, 0x22]) == none
	// a name size of 4 is not valid
	assert heard_path([u8(1), u8(1 | (3 << 6)), 0x11, 0x22, 0x33, 0x44, 0xAA]) == none
	// transport codes cut short
	assert heard_path([u8(0), 1, 2]) == none
}

fn test_path_graph_counts_neighbours_in_order_either_way() {
	mut g := PathGraph{}
	g.record(pkt(1, 1, [u8(0x11), 0x22, 0x33]), 100)
	g.record(pkt(1, 1, [u8(0x33), 0x22]), 200)
	mut pairs := g.take()
	pairs.sort(a.a < b.a)
	assert pairs.len == 2
	assert pairs[0] == SeenPair{'11', '22', 1, 100}
	assert pairs[1] == SeenPair{'22', '33', 2, 200}
	assert g.take().len == 0
}

fn test_path_graph_ignores_short_paths_and_junk() {
	mut g := PathGraph{}
	g.record(pkt(1, 1, [u8(0x11)]), 1)
	g.record(pkt(1, 1, []u8{}), 1)
	g.record([u8(1)], 1)
	g.record(pkt(1, 1, [u8(0x11), 0x11]), 1) // the same name twice in a row is not a link
	assert g.take().len == 0
}

fn test_candidate_edges_maps_names_to_repeaters() {
	reps := [Repeater{'aa1111111111', 'A'}, Repeater{'bb2222222222', 'B'},
		Repeater{'cc3333333333', 'C'}]
	edges := candidate_edges([SeenPair{'aa', 'bb', 3, 1}, SeenPair{'bb', 'cc', 1, 1},
		SeenPair{'dd', 'aa', 1, 1}], reps)
	assert edges.len == 2
	assert edges[0] == Edge{'aa1111111111', 'bb2222222222'}
	assert edges[1] == Edge{'bb2222222222', 'cc3333333333'}
}

fn test_candidate_edges_a_short_name_stands_for_every_repeater_it_fits() {
	reps := [Repeater{'aa1111111111', 'A1'}, Repeater{'aa2222222222', 'A2'},
		Repeater{'bb3333333333', 'B'}]
	edges := candidate_edges([SeenPair{'aa', 'bb', 1, 1}], reps)
	assert edges.len == 2
}

fn test_candidate_edges_drops_a_name_that_fits_too_many() {
	mut reps := []Repeater{}
	for i in 0 .. 6 {
		reps << Repeater{'aa00000000${i:02d}', 'x'}
	}
	reps << Repeater{'bb3333333333', 'B'}
	assert candidate_edges([SeenPair{'aa', 'bb', 1, 1}], reps).len == 0
}

fn test_candidate_edges_no_duplicates() {
	reps := [Repeater{'aa1111111111', 'A'}, Repeater{'bb2222222222', 'B'}]
	edges := candidate_edges([SeenPair{'aa', 'bb', 1, 1}, SeenPair{'aa11', 'bb22', 1, 1}], reps)
	assert edges.len == 1
}

fn test_path_names_reads_hops_of_any_valid_size() {
	assert path_names(2, [u8(0x11), 0x22]) == ['11', '22']
	assert path_names(2 | (1 << 6), [u8(0x11), 0x22, 0x33, 0x44]) == ['1122', '3344']
	assert path_names(0, []u8{}) == []string{}
}

fn test_path_names_ignores_no_path_and_mismatches() {
	assert path_names(0xFF, [u8(1), 2]) == []string{} // no path known
	assert path_names(3, [u8(1), 2]) == []string{} // says 3 hops, has 2 bytes
	assert path_names(1 | (3 << 6), [u8(1), 2, 3, 4]) == []string{} // 4 byte names do not exist
}

fn test_a_contact_path_gives_the_links_along_it() {
	mut g := PathGraph{}
	// the radio reaches the repeater cc33... through aa then bb: aa-bb is a link, and bb-cc since cc is a repeater too
	g.record_contact(2, [u8(0xaa), 0xbb], 'cc3333333333', true, 100)
	mut pairs := g.take()
	pairs.sort(a.a < b.a)
	assert pairs == [SeenPair{'aa', 'bb', 1, 100}, SeenPair{'bb', 'cc', 1, 100}]
}

fn test_a_contact_that_is_not_a_repeater_is_not_a_link_end() {
	mut g := PathGraph{}
	g.record_contact(2, [u8(0xaa), 0xbb], 'cc3333333333', false, 100)
	assert g.take() == [SeenPair{'aa', 'bb', 1, 100}]
}

fn test_a_direct_contact_or_one_with_no_path_adds_nothing() {
	mut g := PathGraph{}
	g.record_contact(0, []u8{}, 'cc3333333333', true, 100) // direct: its link to this node is probed anyway
	g.record_contact(0xFF, []u8{}, 'dd4444444444', true, 100)
	g.record_contact(1, [u8(0xaa)], 'cc3333333333', false, 100) // one repeater and a client: no pair
	assert g.take().len == 0
}

fn test_contact_path_with_wide_names_pairs_with_the_wide_start_of_the_key() {
	mut g := PathGraph{}
	g.record_contact(1 | (1 << 6), [u8(0xaa), 0xa1], 'cc3333333333', true, 100)
	assert g.take() == [SeenPair{'aaa1', 'cc33', 1, 100}]
}
