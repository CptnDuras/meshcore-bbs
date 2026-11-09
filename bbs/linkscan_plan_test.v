module main

// A pretend mesh to answer probes: links is "x|y" -> one-way delay in ms and the SNR each way. A probe is answered only if every hop of its path is
// a real link, exactly like the real trace, which dies at the first hop that cannot hear the one before.
struct FakeLink {
	ms      int
	snr_fwd f64 // heard by the lexically larger end
	snr_rev f64
}

fn fake_answer(links map[string]FakeLink, p Probe) ProbeResult {
	mut at := link_self
	mut snrs := []f64{}
	mut total := 0
	for id in p.path {
		l := links[edge_key(at, id)] or { return ProbeResult{} }
		total += l.ms
		snrs << if id > at { l.snr_fwd } else { l.snr_rev }
		at = id
	}
	l := links[edge_key(at, link_self)] or { return ProbeResult{} }
	total += l.ms
	return ProbeResult{
		ok:        true
		rtt_ms:    total
		snrs:      snrs
		final_snr: if link_self > at { l.snr_fwd } else { l.snr_rev }
	}
}

fn repeaters_of(ids []string) []Repeater {
	return ids.map(Repeater{
		id:   it
		name: it
	})
}

fn test_pick_hash_size_shortest_that_is_unique() {
	assert pick_hash_size(['aa1111111111', 'bb2222222222']) == 1
	assert pick_hash_size(['aa1111111111', 'aa2222222222']) == 2
	assert pick_hash_size(['aabb11111111', 'aabb22222222']) == 4
	assert pick_hash_size([]string{}) == 1
}

fn test_pick_hash_size_gives_up_at_the_longest() {
	assert pick_hash_size(['aabbccdd1111', 'aabbccdd1111']) == 4
}

fn test_probe_path_goes_out_and_straight_back() {
	assert probe_path([]string{}, 'y') == ['y']
	assert probe_path(['a'], 'y') == ['a', 'y', 'a']
	assert probe_path(['a', 'b'], 'y') == ['a', 'b', 'y', 'b', 'a']
}

fn test_hop_readings_one_per_hop_both_ways() {
	r := hop_readings(['a', 'b', 'a'], [1.0, 2.0, 3.0], 4.0)
	assert r.len == 4
	assert r[0] == HopReading{link_self, 'a', 1.0}
	assert r[1] == HopReading{'a', 'b', 2.0}
	assert r[2] == HopReading{'b', 'a', 3.0}
	assert r[3] == HopReading{'a', link_self, 4.0}
}

fn test_hop_readings_ignores_an_answer_that_does_not_fit() {
	assert hop_readings(['a', 'b'], [1.0], 2.0).len == 0
	assert hop_readings([]string{}, []f64{}, 2.0).len == 0
}

fn test_hop_latency_is_half_the_extra_round_trip() {
	assert hop_latency_ms(1000, 0) == 500
	assert hop_latency_ms(1700, 1000) == 350
	assert hop_latency_ms(900, 1000) == 0 // a faster trip than the base (jitter) is not a negative delay
}

fn test_scanner_tries_every_repeater_straight_from_this_node_first() {
	mut s := new_scanner(repeaters_of(['aa', 'bb', 'cc']), []Edge{}, 100)
	mut firsts := []string{}
	for _ in 0 .. 3 {
		p := s.next() or { break }
		assert p.via == link_self
		assert p.path.len == 1
		firsts << p.target
		s.record(p, ProbeResult{})
	}
	assert firsts.len == 3
	assert s.next() == none
}

fn test_scanner_walks_the_whole_mesh() {
	// self-a-b-c-e, plus a-c; d is heard but unreachable; the observed pair a-e does not exist
	links := {
		edge_key(link_self, 'aa'): FakeLink{100, 10.0, 11.0}
		edge_key('aa', 'bb'):      FakeLink{120, 5.0, 6.0}
		edge_key('bb', 'cc'):      FakeLink{140, -3.0, -2.0}
		edge_key('aa', 'cc'):      FakeLink{110, 1.0, 2.0}
		edge_key('cc', 'ee'):      FakeLink{90, 0.5, 0.75}
	}
	reps := repeaters_of(['aa', 'bb', 'cc', 'dd', 'ee'])
	observed := [Edge{'aa', 'bb'}, Edge{'bb', 'cc'}, Edge{'cc', 'ee'}, Edge{'aa', 'ee'},
		Edge{'aa', 'cc'}, Edge{'dd', 'cc'}]
	mut s := new_scanner(reps, observed, 100)
	mut measured := map[string]bool{}
	mut lat := map[string]int{}
	for {
		p := s.next() or { break }
		r := fake_answer(links, p)
		if r.ok {
			measured[edge_key(p.via, p.target)] = true
			lat[edge_key(p.via, p.target)] = hop_latency_ms(r.rtt_ms, p.base_rtt_ms)
		}
		s.record(p, r)
	}
	assert measured[edge_key(link_self, 'aa')]
	assert measured[edge_key('aa', 'bb')]
	assert measured[edge_key('bb', 'cc')]
	assert measured[edge_key('aa', 'cc')]
	assert measured[edge_key('cc', 'ee')]
	assert !measured[edge_key('aa', 'ee')] // not a real link: tried and given up on
	assert !measured[edge_key('dd', 'cc')]
	sum := s.summary()
	assert sum.repeaters == 5
	assert sum.reached == 4 // dd is never reached
	// the delay of every measured link comes out as the link's own one-way delay, whatever route got there
	assert lat[edge_key(link_self, 'aa')] == 100
	assert lat[edge_key('aa', 'bb')] == 120
	assert lat[edge_key('cc', 'ee')] == 90
}

fn test_scanner_reaches_far_links_through_proved_ones() {
	links := {
		edge_key(link_self, 'aa'): FakeLink{100, 1.0, 1.0}
		edge_key('aa', 'bb'):      FakeLink{100, 1.0, 1.0}
		edge_key('bb', 'cc'):      FakeLink{100, 1.0, 1.0}
	}
	mut s := new_scanner(repeaters_of(['aa', 'bb', 'cc']), [Edge{'aa', 'bb'}, Edge{'bb', 'cc'}], 100)
	mut longest := []string{}
	for {
		p := s.next() or { break }
		if p.path.len > longest.len {
			longest = p.path.clone()
		}
		s.record(p, fake_answer(links, p))
	}
	assert longest == ['aa', 'bb', 'cc', 'bb', 'aa']
}

fn test_scanner_stops_at_the_probe_budget() {
	mut s := new_scanner(repeaters_of(['aa', 'bb', 'cc']), []Edge{}, 2)
	mut n := 0
	for {
		p := s.next() or { break }
		s.record(p, ProbeResult{})
		n++
	}
	assert n == 2
}

fn test_scanner_does_not_repeat_a_probe() {
	mut s := new_scanner(repeaters_of(['aa', 'bb']), [Edge{'aa', 'bb'}], 100)
	mut seen := map[string]bool{}
	for {
		p := s.next() or { break }
		k := p.path.join(',')
		assert k !in seen
		seen[k] = true
		s.record(p, ProbeResult{})
	}
}

fn test_scanner_tries_a_failed_link_from_the_other_end() {
	// a is next to us and so is c; b is only linked to c. The observed pair a-b is wrong, b-c is right.
	links := {
		edge_key(link_self, 'aa'): FakeLink{100, 1.0, 1.0}
		edge_key(link_self, 'cc'): FakeLink{100, 1.0, 1.0}
		edge_key('bb', 'cc'):      FakeLink{100, 1.0, 1.0}
	}
	mut s := new_scanner(repeaters_of(['aa', 'bb', 'cc']), [Edge{'aa', 'bb'}, Edge{'cc', 'bb'}], 100)
	mut got_b := false
	for {
		p := s.next() or { break }
		r := fake_answer(links, p)
		if r.ok && p.target == 'bb' {
			got_b = true
			assert p.via == 'cc'
		}
		s.record(p, r)
	}
	assert got_b
}

fn test_scanner_ignores_pairs_of_unknown_repeaters_and_itself() {
	mut s := new_scanner(repeaters_of(['aa']), [Edge{'aa', 'zz'}, Edge{'aa', 'aa'}], 100)
	p := s.next() or { panic('expected the direct probe') }
	assert p.target == 'aa'
	s.record(p, ProbeResult{})
	assert s.next() == none
}

fn test_scanner_will_not_build_a_trace_too_long_for_one_packet() {
	// a chain long enough that its trace would exceed the packet
	mut ids := []string{}
	mut links := map[string]FakeLink{}
	mut obs := []Edge{}
	mut prev := link_self
	for i in 0 .. 40 {
		id := 'a${i:03d}'
		ids << id
		links[edge_key(prev, id)] = FakeLink{50, 1.0, 1.0}
		if prev != link_self {
			obs << Edge{prev, id}
		}
		prev = id
	}
	mut s := new_scanner(repeaters_of(ids), obs, 1000)
	for {
		p := s.next() or { break }
		assert p.path.len * s.hash_size <= trace_max_hash_bytes
		s.record(p, fake_answer(links, p))
	}
}
