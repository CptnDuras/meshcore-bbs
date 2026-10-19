module main

import os

// Where help text comes from. The text itself is data, never source code:
//
//   1. the database       (tables help_topics / help_commands / help_messages;
//                         HELPIMPORT fills them from a file)
//   2. a config file      (./help.txt beside the daemon)
//   3. the built-in file  (bbs/help.txt, compiled in as an asset so a bare binary
//                         still has help)
//
// The first source that has content wins. Each source is turned into a HelpData,
// which is a HelpCatalog; the help service never learns where it came from.
// The file format is documented at the top of bbs/help.txt.

const embedded_help_text = $embed_file('help.txt')

// help_db_empty is the error help_data_from_store returns when nothing was imported.
const help_db_empty = 'no help in the database'

// help_message_names are the messages every catalog must provide.
const help_message_names = ['menu_header', 'no_topic', 'welcome']

// HelpData is an in-memory HelpCatalog.
struct HelpData {
mut:
	topic_list []HelpTopic
	cmd_list   []HelpCommand
	msgs       map[string]string
}

fn (d HelpData) topics() []HelpTopic {
	return d.topic_list
}

fn (d HelpData) commands() []HelpCommand {
	return d.cmd_list
}

fn (d HelpData) message(name string) string {
	return d.msgs[name] or { '' }
}

// perm_from_name maps a perm: header to a level.
fn perm_from_name(s string) ?Perm {
	return match s.trim_space().to_lower() {
		'unverified', '' { Perm.unverified }
		'user' { Perm.user }
		'aide' { Perm.aide }
		'sysop' { Perm.sysop }
		else { none }
	}
}

// validate checks a loaded catalog is usable: topic numbers 1-9 and unique,
// every command belongs to a real topic and has a usage and summary, no command
// name is documented twice, and the required messages exist.
fn (d HelpData) validate() ! {
	if d.topic_list.len == 0 {
		return error('no topics')
	}
	mut nums := map[int]bool{}
	mut keys := map[string]bool{}
	for t in d.topic_list {
		if t.num < 1 || t.num > 9 {
			return error('topic "${t.key}": number must be 1-9, got ${t.num}')
		}
		if nums[t.num] {
			return error('topic number ${t.num} used twice')
		}
		if t.key == 'all' {
			return error('topic key "all" is reserved for HELP ALL')
		}
		if t.title.len == 0 {
			return error('topic "${t.key}" needs a title')
		}
		nums[t.num] = true
		keys[t.key] = true
	}
	mut seen := map[string]bool{}
	for c in d.cmd_list {
		if c.names.len == 0 {
			return error('a command entry has no names')
		}
		if c.usage.len == 0 || c.summary.len == 0 {
			return error('command ${c.names[0]} needs usage and summary')
		}
		if !keys[c.topic] {
			return error('command ${c.names[0]}: unknown topic "${c.topic}"')
		}
		for n in c.names {
			if seen[n] {
				return error('command name ${n} documented twice')
			}
			seen[n] = true
		}
	}
	for n in help_message_names {
		if d.msgs[n].len == 0 {
			return error('missing [message ${n}]')
		}
	}
}

fn split_list(s string) []string {
	return s.split(',').map(it.trim_space()).filter(it.len > 0)
}

// parse_help_text reads the help file format into a validated HelpData.
fn parse_help_text(text string) !HelpData {
	mut d := HelpData{
		msgs: map[string]string{}
	}
	mut kind := '' // topic | command | message | '' (comments before the first section)
	mut topic := HelpTopic{}
	mut cmd := HelpCommand{}
	mut msg_name := ''
	mut buf := []string{}

	for raw in text.split('\n') {
		line := raw.trim_right('\r')
		t := line.trim_space()
		if t.starts_with('[') && t.ends_with(']') {
			close_help_section(mut d, kind, topic, cmd, msg_name, buf)
			buf = []string{}
			kind = ''
			parts := t.trim('[]').split(' ').filter(it.len > 0)
			if parts.len == 2 && parts[0] == 'message' {
				kind = 'message'
				msg_name = parts[1]
			} else if parts.len == 3 && parts[0] == 'topic' && parts[1].len > 0
				&& parts[1].bytes().all(it >= `0` && it <= `9`) {
				kind = 'topic'
				topic = HelpTopic{
					num: parts[1].int()
					key: parts[2].to_lower()
				}
			} else if parts.len == 2 && parts[0] == 'command' {
				kind = 'command'
				cmd = HelpCommand{
					names: [parts[1].to_upper()]
				}
			} else {
				return error('bad section header "${t}"')
			}
			continue
		}
		match kind {
			'message' {
				buf << line
			}
			'topic', 'command' {
				if t.len == 0 || t.starts_with('#') {
					continue
				}
				name := t.all_before(':').trim_space().to_lower()
				val := t.all_after(':').trim_space()
				if kind == 'topic' {
					match name {
						'title' { topic.title = val }
						'aliases' { topic.aliases = split_list(val.to_lower()) }
						'perm' {
							topic.min_perm = perm_from_name(val) or { return error('topic "${topic.key}": unknown perm "${val}"') }
						}
						'try' { topic.try_cmd = val }
						'note' { topic.notes << val }
						else { return error('topic "${topic.key}": unknown header "${name}"') }
					}
				} else {
					match name {
						'names' { cmd.names = split_list(val.to_upper()) }
						'topic' { cmd.topic = val.to_lower() }
						'usage' { cmd.usage = val }
						'summary' { cmd.summary = val }
						'example' { cmd.example = val }
						'perm' {
							cmd.min_perm = perm_from_name(val) or { return error('command ${cmd.names[0]}: unknown perm "${val}"') }
						}
						else { return error('command ${cmd.names[0]}: unknown header "${name}"') }
					}
				}
			}
			else {}
		}
	}
	close_help_section(mut d, kind, topic, cmd, msg_name, buf)
	d.validate()!
	return d
}

// close_help_section stores the section that just ended.
fn close_help_section(mut d HelpData, kind string, topic HelpTopic, cmd HelpCommand, msg_name string, buf []string) {
	match kind {
		'topic' { d.topic_list << topic }
		'command' { d.cmd_list << cmd }
		'message' { d.msgs[msg_name] = trim_blank_lines(buf).join('\n') }
		else {}
	}
}

fn trim_blank_lines(lines []string) []string {
	mut a := 0
	mut b := lines.len
	for a < b && lines[a].trim_space().len == 0 {
		a++
	}
	for b > a && lines[b - 1].trim_space().len == 0 {
		b--
	}
	return lines[a..b].clone()
}

// help_data_from_embedded is source 3, the compiled-in default file.
fn help_data_from_embedded() !HelpData {
	return parse_help_text(embedded_help_text.to_string())
}

// help_data_from_file is source 2, a config file on disk.
fn help_data_from_file(path string) !HelpData {
	text := os.read_file(path) or { return error('cannot read ${path}: ${err}') }
	return parse_help_text(text)
}

// help_data_from_rows converts database rows into a validated HelpData.
fn help_data_from_rows(topics []HelpTopicRow, cmds []HelpCommandRow, msgs []HelpMessageRow) !HelpData {
	mut d := HelpData{
		msgs: map[string]string{}
	}
	for r in topics {
		perm := perm_from_name(r.perm) or {
			return error('topic "${r.key}": unknown perm "${r.perm}"')
		}
		d.topic_list << HelpTopic{
			num:      r.num
			key:      r.key
			title:    r.title
			aliases:  split_list(r.aliases)
			try_cmd:  r.try_cmd
			notes:    r.notes.split('\n').filter(it.len > 0)
			min_perm: perm
		}
	}
	for r in cmds {
		perm := perm_from_name(r.perm) or {
			return error('command ${r.names}: unknown perm "${r.perm}"')
		}
		d.cmd_list << HelpCommand{
			names:    split_list(r.names)
			topic:    r.topic
			usage:    r.usage
			summary:  r.summary
			example:  r.example
			min_perm: perm
		}
	}
	for m in msgs {
		d.msgs[m.name] = m.text
	}
	d.validate()!
	return d
}

// help_data_from_store is source 1. It fails with help_db_empty when the database holds no help, and
// with another error when it holds help that does not validate.
fn help_data_from_store(mut store Store) !HelpData {
	topics := store.list_help_topics()
	if topics.len == 0 {
		return error(help_db_empty)
	}
	return help_data_from_rows(topics, store.list_help_commands(), store.list_help_messages())
}

// import_help_into_store copies a help file into the database (HELPIMPORT).
// The file is validated first, so a bad file never replaces good data.
fn import_help_into_store(mut store Store, path string) !int {
	d := help_data_from_file(path)!
	mut topics := []HelpTopicRow{}
	for t in d.topic_list {
		topics << HelpTopicRow{
			num:     t.num
			key:     t.key
			title:   t.title
			aliases: t.aliases.join(', ')
			perm:    t.min_perm.str_name()
			try_cmd: t.try_cmd
			notes:   t.notes.join('\n')
		}
	}
	mut cmds := []HelpCommandRow{}
	for c in d.cmd_list {
		cmds << HelpCommandRow{
			names:   c.names.join(', ')
			topic:   c.topic
			usage:   c.usage
			summary: c.summary
			example: c.example
			perm:    c.min_perm.str_name()
		}
	}
	mut msgs := []HelpMessageRow{}
	for name, text in d.msgs {
		msgs << HelpMessageRow{
			name: name
			text: text
		}
	}
	store.replace_help(topics, cmds, msgs)!
	return topics.len
}

// load_help_renderer applies the source order above and returns the renderer
// plus a note on where the text came from. A source that exists but is broken
// is reported in the note and skipped, so a typo never leaves users without help.
fn load_help_renderer(mut store Store, path string) (HelpRenderer, string) {
	mut problems := []string{}
	db := help_data_from_store(mut store) or {
		if err.msg() != help_db_empty {
			problems << 'database help: ${err.msg()}'
		}
		HelpData{}
	}
	if db.topic_list.len > 0 {
		return new_help_service(db), 'database (${db.topic_list.len} topics)'
	}
	if os.exists(path) {
		f := help_data_from_file(path) or {
			problems << '${path}: ${err.msg()}'
			HelpData{}
		}
		if f.topic_list.len > 0 {
			return new_help_service(f), '${path} (${f.topic_list.len} topics)'
		}
	}
	d := help_data_from_embedded() or { panic('built-in help.txt is invalid: ${err}') }
	note := 'built-in help.txt (${d.topic_list.len} topics)'
	return new_help_service(d), if problems.len > 0 {
		note + '; skipped: ' + problems.join('; ')
	} else {
		note
	}
}

// default_help_renderer is the zero-config wiring (the built-in file); the
// daemon replaces it with load_help_renderer at startup.
fn default_help_renderer() HelpRenderer {
	d := help_data_from_embedded() or { panic('built-in help.txt is invalid: ${err}') }
	return new_help_service(d)
}
