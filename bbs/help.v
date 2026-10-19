module main

// Guided help.
//
// A 160-byte radio message cannot carry a command reference, so help is a short
// numbered menu and one small topic per number:
//
//   HELP        the menu            HELP 2 / HELP mail   one topic
//   HELP ALL    every command       2 (a bare digit)     same as HELP 2
//
// Design (SOLID, with dependency injection):
//   - HelpCatalog   (interface) owns the CONTENT. Swap it to change the wording,
//                   load topics from a file, or translate, without touching logic.
//   - HelpViewer    (interface) is the only thing help knows about the asker: their
//                   permission level and whether they are new. It is not the
//                   Engine, the Store or a Session, so help can be tested alone.
//   - HelpRenderer  (interface) is what the Engine depends on. HelpService is the
//                   default implementation; it is handed a catalog, never builds one.
//   - Adding a topic is a data change in the catalog (open/closed); the service
//     has no per-topic code.
//   - The Engine receives its renderer through a field, so a test (or another
//     front end) can inject a different one.

// HelpTopic is one screen of help. `num` is the digit users reply with.
struct HelpTopic {
	num      int
	key      string
	title    string
	aliases  []string
	body     string
	min_perm Perm = .unverified // who may see it (admin topics are gated)
}

// HelpCatalog supplies the topics, in menu order.
interface HelpCatalog {
	topics() []HelpTopic
}

// HelpViewer is what help needs to know about the person asking.
interface HelpViewer {
	perm() Perm
	is_new() bool
}

// HelpRenderer turns a help request into reply text.
interface HelpRenderer {
	// render answers HELP <query>: the menu for '', otherwise one topic.
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

// default_help_renderer is the production wiring: the built-in catalog.
fn default_help_renderer() HelpRenderer {
	return new_help_service(StaticHelpCatalog{})
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

fn (s HelpService) menu(v HelpViewer) string {
	mut b := 'HELP - reply with a number:'
	for t in s.visible(v) {
		b += '\n${t.num} ${t.title}'
	}
	return b
}

fn (s HelpService) find(query string, v HelpViewer) ?HelpTopic {
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

fn (s HelpService) render(query string, v HelpViewer) string {
	if query.trim_space().len == 0 {
		return s.menu(v)
	}
	if t := s.find(query, v) {
		return t.body
	}
	return 'No help topic "${query.trim_space()}".\n' + s.menu(v)
}

fn (s HelpService) topic_for_digit(digit string, v HelpViewer) ?string {
	if digit.len != 1 || digit[0] < `1` || digit[0] > `9` {
		return none
	}
	t := s.find(digit, v) or { return none }
	return t.body
}

fn (s HelpService) welcome(bbs string, who string) string {
	return 'Welcome to ${bbs}! You are ${who} (an account was made for you, no signup). Start here: 1) K lists the rooms 2) C general goes into one 3) R reads it. Send HELP any time for a guided menu.'
}

// StaticHelpCatalog is the built-in content. Each body fits one radio message
// (150 bytes) and ends with something to try, so the next step is obvious.
struct StaticHelpCatalog {}

fn (c StaticHelpCatalog) topics() []HelpTopic {
	return [
		HelpTopic{
			num:     1
			key:     'rooms'
			title:   'Rooms & posts'
			aliases: ['room', 'read', 'post', 'posts', 'board', 'boards']
			body:    'ROOMS & POSTS\nK = list rooms\nC <room> = go to one\nN = new msgs, R = read\nE <subject> = write a post, end with . alone\nTry: K'
		},
		HelpTopic{
			num:     2
			key:     'mail'
			title:   'Mail & people'
			aliases: ['people', 'tell', 'chat', 'dm']
			body:    'MAIL & PEOPLE\nMAIL <user> = write mail, end with .\nMAILBOX = read it\nTELL <user> <msg> = quick note\nW = who is here\nTry: W'
		},
		HelpTopic{
			num:     3
			key:     'weather'
			title:   'Weather & alerts'
			aliases: ['wx', 'alerts', 'alert', 'forecast', 'news']
			body:    'WEATHER\nWX = now, FORECAST = next days\nALERTS = NWS Sheridan/Johnson\nNEWS = local news\nAlerts DM you; stop: CONFIG SET alerts off\nTry: WX'
		},
		HelpTopic{
			num:     4
			key:     'fun'
			title:   'Fun'
			aliases: ['games', 'polls', 'poll']
			body:    'FUN\nFORTUNE  JOKE  ROLL 2d6  8BALL <q>\nO <text> = oneliner\nPOLL, then VOTE <id> <n>\nB = bulletins\nTry: JOKE'
		},
		HelpTopic{
			num:     5
			key:     'account'
			title:   'Your account'
			aliases: ['claim', 'login', 'config', 'me']
			body:    'ACCOUNT\nYou have one already. To keep it on any device:\nCLAIM <name> <pass>\nLater: LOGIN <name> <pass>, Q logs out\n/CONFIG = prefs\nTry: CLAIM'
		},
		HelpTopic{
			num:     6
			key:     'all'
			title:   'All commands'
			aliases: ['commands', 'list', 'full']
			body:    'ALL COMMANDS\nH MENU K C N G R L W WX SW NEWS FORECAST ALERTS\nO B CALLERS PROFILE POLL VOTE RESULTS FORTUNE ROLL 8BALL JOKE CHANNELS STATS\nE MAIL MAILBOX CHECKMAIL THREAD TELL SETBIO\nCLAIM SETPASS LOGIN Q /CONFIG'
		},
		HelpTopic{
			num:      7
			key:      'aide'
			title:    'Moderation'
			aliases:  ['mod', 'moderator']
			body:     'AIDE\nVERIFY <u>  PROMOTE/DEMOTE/TWIT <u>\nBAN/UNBAN <u>  DELETE <id>'
			min_perm: .aide
		},
		HelpTopic{
			num:      8
			key:      'sysop'
			title:    'Sysop'
			aliases:  ['admin']
			body:     'SYSOP\nBULLET <title>|<body>\nALERTTEST [CHAN|ALL|<node>] = test weather alert'
			min_perm: .sysop
		},
	]
}
