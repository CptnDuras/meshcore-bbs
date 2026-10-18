module main

// A tiny dependency-free JSON reader. V's json2 crashed parsing NWS responses on
// FreeBSD and `json` is gone, so (like wx.v/forecast.v) we avoid both. This
// builds a small tree; the callers pull a few fields out of it.

enum JKind {
	null_
	bool_
	num
	str
	arr
	obj
}

struct JVal {
mut:
	kind JKind
	s    string // str, or the raw text of a num/bool
	arr  []JVal
	obj  map[string]JVal
}

fn (v JVal) str_of(key string) string {
	x := v.obj[key] or { return '' }
	return if x.kind == .str { x.s } else { '' }
}

fn (v JVal) get(key string) JVal {
	return v.obj[key] or { JVal{} }
}

struct JParser {
	src string
mut:
	i int
}

// parse_json returns none on malformed input. Depth is capped so hostile input
// cannot blow the stack.
fn parse_json(src string) ?JVal {
	mut p := JParser{
		src: src
	}
	v := p.value(0) or { return none }
	p.ws()
	if p.i != p.src.len {
		return none
	}
	return v
}

fn (mut p JParser) ws() {
	for p.i < p.src.len && p.src[p.i] in [u8(` `), `\t`, `\n`, `\r`] {
		p.i++
	}
}

fn (mut p JParser) value(depth int) ?JVal {
	if depth > 32 {
		return none
	}
	p.ws()
	if p.i >= p.src.len {
		return none
	}
	c := p.src[p.i]
	match c {
		`{` {
			p.i++
			mut o := JVal{
				kind: .obj
			}
			p.ws()
			if p.i < p.src.len && p.src[p.i] == `}` {
				p.i++
				return o
			}
			for {
				p.ws()
				k := p.string_() or { return none }
				p.ws()
				if p.i >= p.src.len || p.src[p.i] != `:` {
					return none
				}
				p.i++
				v := p.value(depth + 1) or { return none }
				o.obj[k] = v
				p.ws()
				if p.i >= p.src.len {
					return none
				}
				if p.src[p.i] == `,` {
					p.i++
					continue
				}
				if p.src[p.i] == `}` {
					p.i++
					return o
				}
				return none
			}
		}
		`[` {
			p.i++
			mut a := JVal{
				kind: .arr
			}
			p.ws()
			if p.i < p.src.len && p.src[p.i] == `]` {
				p.i++
				return a
			}
			for {
				v := p.value(depth + 1) or { return none }
				a.arr << v
				p.ws()
				if p.i >= p.src.len {
					return none
				}
				if p.src[p.i] == `,` {
					p.i++
					continue
				}
				if p.src[p.i] == `]` {
					p.i++
					return a
				}
				return none
			}
		}
		`"` {
			s := p.string_() or { return none }
			return JVal{
				kind: .str
				s:    s
			}
		}
		else {
			start := p.i
			for p.i < p.src.len && p.src[p.i] !in [u8(`,`), `}`, `]`, ` `, `\t`, `\n`, `\r`] {
				p.i++
			}
			tok := p.src[start..p.i]
			if tok == 'null' {
				return JVal{}
			}
			if tok == 'true' || tok == 'false' {
				return JVal{
					kind: .bool_
					s:    tok
				}
			}
			if tok.len > 0 && (tok[0] == `-` || (tok[0] >= `0` && tok[0] <= `9`)) {
				return JVal{
					kind: .num
					s:    tok
				}
			}
			return none
		}
	}
	return none
}

// string_ reads a JSON string at p.i (which must be on the opening quote).
// \uXXXX escapes decode to UTF-8; unknown escapes keep the escaped character.
fn (mut p JParser) string_() ?string {
	if p.i >= p.src.len || p.src[p.i] != `"` {
		return none
	}
	p.i++
	mut out := []u8{}
	for p.i < p.src.len {
		c := p.src[p.i]
		if c == `"` {
			p.i++
			return out.bytestr()
		}
		if c == `\\` {
			p.i++
			if p.i >= p.src.len {
				return none
			}
			e := p.src[p.i]
			match e {
				`n` { out << `\n` }
				`t` { out << `\t` }
				`r` { out << `\r` }
				`b` { out << 8 }
				`f` { out << 12 }
				`u` {
					if p.i + 4 >= p.src.len {
						return none
					}
					cp := int(('0x' + p.src[p.i + 1..p.i + 5]).parse_int(16, 32) or { return none })
					p.i += 4
					out << utf32_to_str(u32(cp)).bytes()
				}
				else { out << e }
			}
			p.i++
			continue
		}
		out << c
		p.i++
	}
	return none
}
