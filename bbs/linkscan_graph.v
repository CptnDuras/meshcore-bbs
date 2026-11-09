module main

import sync

// Which repeaters sit next to each other in the paths of packets the radio hears. Every forwarded packet carries the names (the first bytes of the
// public key) of the repeaters it passed through, so two names side by side mean those two repeaters could hear each other. That is a good list
// of links to measure, and far shorter than trying every pair.
//
// Layout (MeshCore src/Packet.cpp): header(1) [transport codes(4) when the route type is 0 or 3] path_len(1) path payload.
// path_len: low 6 bits are the number of hops, high 2 bits the name size minus one.

const graph_max_pairs = 20000
const path_max_bytes = 64
const max_names_per_end = 4 // a short name can fit many repeaters; past this the pair says too little to be worth probing

// HeardPath is the list of repeater names (hex) a packet came through, in the order it was forwarded.
pub struct HeardPath {
pub:
	names []string
}

// heard_path reads the path out of a raw packet. none for anything that does not parse.
pub fn heard_path(raw []u8) ?HeardPath {
	if raw.len < 3 {
		return none
	}
	route_type := int(raw[0] & 0x03)
	mut i := 1
	if route_type == 0 || route_type == 3 {
		i += 4
	}
	if i >= raw.len {
		return none
	}
	path_len := raw[i]
	i++
	hops := int(path_len & 63)
	size := int(path_len >> 6) + 1
	if size == 4 || hops * size > path_max_bytes || i + hops * size >= raw.len {
		return none
	}
	mut names := []string{}
	for _ in 0 .. hops {
		names << raw[i..i + size].hex()
		i += size
	}
	return HeardPath{names}
}

// SeenPair is two names that were side by side in a path, a before b in lexical order, and how often.
pub struct SeenPair {
pub mut:
	a    string
	b    string
	n    int
	last i64
}

// PathGraph collects the pairs between flushes. record is called from the radio's callback for every packet, so it takes a lock briefly and does
// nothing else.
pub struct PathGraph {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	pairs map[string]SeenPair
}

pub fn (mut g PathGraph) record(raw []u8, now i64) {
	hp := heard_path(raw) or { return }
	g.note(hp.names, now)
}

// record_contact takes the path the radio uses to reach a contact (from its contact book): the repeaters in order, so each neighbouring pair is
// a link the radio found worth using. A repeater contact is also the end of its own path, so the last repeater on it is paired with the contact.
pub fn (mut g PathGraph) record_contact(path_len u8, path []u8, id string, is_repeater bool, now i64) {
	mut names := path_names(path_len, path)
	if names.len == 0 {
		return
	}
	size := int(path_len >> 6) + 1
	if is_repeater && id.len >= size * 2 {
		names << id[..size * 2]
	}
	g.note(names, now)
}

// path_names cuts a path (path_len says how many names and how long each is, as in a packet) into hex names. Empty for no path (0xFF) or a
// path that does not fit its length.
pub fn path_names(path_len u8, path []u8) []string {
	if path_len == 0xFF {
		return []string{}
	}
	hops := int(path_len & 63)
	size := int(path_len >> 6) + 1
	if size == 4 || hops * size != path.len {
		return []string{}
	}
	mut names := []string{}
	for i in 0 .. hops {
		names << path[i * size..(i + 1) * size].hex()
	}
	return names
}

// note counts each pair of neighbours in a list of names.
fn (mut g PathGraph) note(names []string, now i64) {
	if names.len < 2 {
		return
	}
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	for i in 0 .. names.len - 1 {
		x, y := names[i], names[i + 1]
		if x == y {
			continue
		}
		a, b := if x < y { x, y } else { y, x }
		k := '${a}|${b}'
		mut p := g.pairs[k] or {
			if g.pairs.len >= graph_max_pairs {
				continue
			}
			SeenPair{
				a: a
				b: b
			}
		}
		p.n++
		p.last = now
		g.pairs[k] = p
	}
}

// take hands over what has been collected and starts again.
pub fn (mut g PathGraph) take() []SeenPair {
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	out := g.pairs.values()
	g.pairs.clear()
	return out
}

// candidate_edges turns pairs of names into pairs of repeaters. A name that fits no known repeater says nothing; one that fits several stands for
// each of them (the probe settles which is real) up to max_names_per_end, past which it is dropped.
pub fn candidate_edges(pairs []SeenPair, reps []Repeater) []Edge {
	mut out := []Edge{}
	mut seen := map[string]bool{}
	for p in pairs {
		xs := reps.filter(it.id.starts_with(p.a)).map(it.id)
		ys := reps.filter(it.id.starts_with(p.b)).map(it.id)
		if xs.len == 0 || ys.len == 0 || xs.len > max_names_per_end || ys.len > max_names_per_end {
			continue
		}
		for x in xs {
			for y in ys {
				k := edge_key(x, y)
				if x == y || k in seen {
					continue
				}
				seen[k] = true
				out << Edge{x, y}
			}
		}
	}
	return out
}
