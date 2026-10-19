module main

// Guided help.
//
// A 160-byte radio message cannot carry a command reference, so help is a short
// numbered menu, one small screen per topic, and one entry per command:
//
//   HELP         the menu              HELP 2 / HELP mail   one topic screen
//   HELP ALL     every command         HELP MAIL            one command's usage
//   2            same as HELP 2
//
// There is no help text in this file. The wording lives in data (the database
// or help.txt; see help_catalog.v) and reaches the service through a
// HelpCatalog. Each command has its own entry there, keyed by the command's
// name in the command registry; a topic screen is composed from the entries of
// the commands that belong to it, so a command's help lives with that command
// and cannot drift from the topic lists.
//
// Design (SOLID, with dependency injection):
//   - HelpCatalog   (interface) supplies topics, command entries and messages.
//                   Files, the database or a test fake all fit; none is built here.
//   - HelpViewer    (interface) is the only thing help knows about the asker: their
//                   permission level and whether they are new. It is not the
//                   Engine, the Store or a Session, so help can be tested alone.
//   - HelpRenderer  (interface) is what the Engine depends on. HelpService is the
//                   default implementation; it is handed a catalog, never builds one.
//   - Adding a command or topic is a data change (open/closed); the service has
//     no per-command code.
//   - The Engine receives its renderer through a field, so a test (or another
//     front end) can inject a different one.

// HelpTopic is one screen of help. `num` is the digit users reply with.
struct HelpTopic {
mut:
	num      int
	key      string
	title    string
	aliases  []string
	try_cmd  string   // a command to suggest at the bottom of the screen
	notes    []string // extra lines shown after the commands
	min_perm Perm = .unverified // who may see it (admin topics are gated)
}

// HelpCommand is the help entry for one registered command.
struct HelpCommand {
mut:
	names    []string // exactly the registry names: names[0] is the primary
	topic    string   // key of the topic whose screen lists it
	usage    string   // how to type it, e.g. "MAIL <user>"
	summary  string   // what it does, in a few words
	example  string   // optional worked example shown by HELP <command>
	min_perm Perm = .unverified
}

// HelpCatalog supplies the topics, the per-command entries (in registry
// order) and the named messages (menu_header, menu_footer, no_topic, welcome).
interface HelpCatalog {
	topics() []HelpTopic
	commands() []HelpCommand
	message(name string) string
}

// HelpViewer is what help needs to know about the person asking.
interface HelpViewer {
	perm() Perm
	is_new() bool
}

// HelpRenderer turns a help request into reply text.
interface HelpRenderer {
	// render answers HELP <query>: the menu for '', otherwise a topic, a
	// command, or ALL.
	render(query string, v HelpViewer) string
	// topic_for_digit answers a bare digit sent as a command; none if no such topic.
	topic_for_digit(digit string, v HelpViewer) ?string
	// welcome is the one-time first-contact message.
	welcome(bbs string, who string) string
}

// SessionViewer is the HelpViewer the Engine builds from the current user.
struct SessionViewer {
	level Perm
	fresh bool
}

fn (s SessionViewer) perm() Perm {
	return s.level
}

fn (s SessionViewer) is_new() bool {
	return s.fresh
}

// HelpService is the default HelpRenderer. It holds no content of its own.
struct HelpService {
	catalog HelpCatalog @[required]
}

// new_help_service wires the service to a catalog.
fn new_help_service(catalog HelpCatalog) HelpService {
	return HelpService{
		catalog: catalog
	}
}

fn (s HelpService) visible(v HelpViewer) []HelpTopic {
	mut out := []HelpTopic{}
	for t in s.catalog.topics() {
		if int(v.perm()) >= int(t.min_perm) {
			out << t
		}
	}
	return out
}

// commands_of lists the entries on a topic the viewer may see, in catalog order.
fn (s HelpService) commands_of(topic string, v HelpViewer) []HelpCommand {
	mut out := []HelpCommand{}
	for c in s.catalog.commands() {
		if c.topic == topic && int(v.perm()) >= int(c.min_perm) {
			out << c
		}
	}
	return out
}

fn (s HelpService) menu(v HelpViewer) string {
	mut b := s.catalog.message('menu_header')
	for t in s.visible(v) {
		b += '\n${t.num} ${t.title}'
	}
	footer := s.catalog.message('menu_footer')
	if footer.len > 0 {
		b += '\n' + footer
	}
	return b
}

// screen composes a topic's screen from its commands' entries.
fn (s HelpService) screen(t HelpTopic, v HelpViewer) string {
	mut lines := [t.title.to_upper()]
	for c in s.commands_of(t.key, v) {
		lines << '${c.usage} = ${c.summary}'
	}
	lines << t.notes
	if t.try_cmd.len > 0 {
		lines << 'Try: ${t.try_cmd}'
	}
	return lines.join('\n')
}

// all lists every command the viewer may use, by topic, using each command's
// shortest name. It is generated, so it cannot omit a command that has an entry.
fn (s HelpService) all(v HelpViewer) string {
	mut lines := []string{}
	for t in s.visible(v) {
		cmds := s.commands_of(t.key, v)
		if cmds.len == 0 {
			continue
		}
		mut names := []string{}
		for c in cmds {
			names << shortest_name(c.names)
		}
		lines << '${t.title}: ${names.join(' ')}'
	}
	return lines.join('\n')
}

fn shortest_name(names []string) string {
	mut best := names[0]
	for n in names {
		if n.len < best.len {
			best = n
		}
	}
	return best
}

fn (s HelpService) find_topic(query string, v HelpViewer) ?HelpTopic {
	q := query.trim_space().to_lower()
	if q.len == 0 {
		return none
	}
	for t in s.visible(v) {
		if q == t.num.str() || q == t.key || q in t.aliases {
			return t
		}
	}
	return none
}

fn (s HelpService) find_command(query string, v HelpViewer) ?HelpCommand {
	q := query.trim_space().to_upper()
	if q.len == 0 {
		return none
	}
	for c in s.catalog.commands() {
		if q in c.names && int(v.perm()) >= int(c.min_perm) {
			return c
		}
	}
	return none
}

fn (s HelpService) command_page(c HelpCommand) string {
	mut b := '${c.usage} - ${c.summary}'
	if c.names.len > 1 {
		b += '\nAlso: ' + c.names[1..].join(' ')
	}
	if c.example.len > 0 {
		b += '\nEx: ${c.example}'
	}
	return b
}

fn (s HelpService) render(query string, v HelpViewer) string {
	q := query.trim_space()
	if q.len == 0 {
		return s.menu(v)
	}
	if q.to_lower() == 'all' {
		return s.all(v)
	}
	// a number is a topic pick; otherwise a command name wins over a topic word
	// (HELP MAIL is the command, HELP 2 the mail screen)
	if q.bytes().all(it >= `0` && it <= `9`) {
		if t := s.find_topic(q, v) {
			return s.screen(t, v)
		}
	}
	if c := s.find_command(q, v) {
		return s.command_page(c)
	}
	if t := s.find_topic(q, v) {
		return s.screen(t, v)
	}
	return s.catalog.message('no_topic').replace('{query}', q) + '\n' + s.menu(v)
}

fn (s HelpService) topic_for_digit(digit string, v HelpViewer) ?string {
	if digit.len != 1 || digit[0] < `1` || digit[0] > `9` {
		return none
	}
	t := s.find_topic(digit, v) or { return none }
	return s.screen(t, v)
}

fn (s HelpService) welcome(bbs string, who string) string {
	return s.catalog.message('welcome').replace('{bbs}', bbs).replace('{who}', who)
}
