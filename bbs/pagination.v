module main

// Pagination splits long BBS output into mesh-sized messages.
// MeshCore text messages cap at 160 bytes; we stay under that. All pages of a
// reply are sent in one turn (the daemon spaces them out for airtime); there is
// no interactive continue prompt — it collided with the C (CHANGE room) command
// and the continue state was never wired through anyway.

pub const msg_max = 150 // leave headroom under the 160-byte limit

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

// burst returns the messages to send this turn. All pages are sent (no cap, no
// continue prompt). The extra return values are kept for call-site
// compatibility: next is always pages.len and more is always false.
pub fn burst(pages []string, offset int) ([]string, int, bool) {
	mut msgs := []string{}
	for i in offset .. pages.len {
		msgs << pages[i]
	}
	return msgs, pages.len, false
}
