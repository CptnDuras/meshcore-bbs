module main

// Pagination splits long BBS output into mesh-sized messages.
// MeshCore text messages cap at 160 bytes; we stay under that and also cap how
// many messages we emit in one burst (good mesh citizenship) — the rest waits
// behind a [C]ontinue prompt.

pub const msg_max = 150 // leave headroom under the 160-byte limit
pub const burst_cap = 3 // max messages sent per turn before [C]ontinue

// paginate splits `text` into <=msg_max byte chunks, breaking on newlines/space
// where possible.
pub fn paginate(text string) []string {
	mut out := []string{}
	mut cur := ''
	for line in text.split('\n') {
		mut l := line
		// hard-wrap overly long single lines
		for l.len > msg_max {
			out << l[..msg_max]
			l = l[msg_max..]
		}
		if cur.len == 0 {
			cur = l
		} else if cur.len + 1 + l.len <= msg_max {
			cur = cur + '\n' + l
		} else {
			out << cur
			cur = l
		}
	}
	if cur.len > 0 {
		out << cur
	}
	if out.len == 0 {
		out << ''
	}
	return out
}

// burst returns the messages to send this turn (up to burst_cap starting at
// offset) and the new offset; more_remaining indicates a [C]ontinue is needed.
pub fn burst(pages []string, offset int) ([]string, int, bool) {
	mut msgs := []string{}
	mut i := offset
	for i < pages.len && msgs.len < burst_cap {
		msgs << pages[i]
		i++
	}
	more := i < pages.len
	if more {
		msgs << '--- more: send C to continue ---'
	}
	return msgs, i, more
}
