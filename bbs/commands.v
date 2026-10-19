module main

// The command registry. Every BBS command is one small function with the
// CommandHandler signature, registered by name; Engine.dispatch only looks the
// name up and calls it. Features register their own commands (see cmd_*.v), so
//
//   - a feature is atomic: its commands, handlers and tests live together and a
//     test can register just that feature into an empty registry;
//   - adding a command touches only its feature file and its help entry;
//   - the Engine depends on the CommandSource interface, not on a list of
//     commands, so another front end or a test can inject its own set.
//
// Each command also has a help entry in the help data (help.txt / database),
// keyed by the command's primary name; a test fails if a command has none.

// CommandHandler runs one command for one session and returns the reply text.
type CommandHandler = fn (mut e Engine, mut sess Session, args string) string

// Command is a registered command. names[0] is the primary name (the one the
// help entry is keyed by); the rest are aliases. Names are upper-case.
struct Command {
	names   []string
	handler CommandHandler @[required]
}

// CommandSource is what the Engine needs from a set of commands.
interface CommandSource {
	// find returns the command with this name or alias (any case).
	find(name string) ?Command
	// all returns every command in registration order.
	all() []Command
}

// CommandRegistry is the standard CommandSource.
struct CommandRegistry {
mut:
	list  []Command
	index map[string]int
}

// add registers a command. A name used twice is a programming error, so it
// panics at startup (and in the registry tests) instead of shadowing silently.
fn (mut r CommandRegistry) add(names []string, handler CommandHandler) {
	for n in names {
		if n.to_upper() in r.index {
			panic('command name registered twice: ${n}')
		}
	}
	r.list << Command{
		names:   names.map(it.to_upper())
		handler: handler
	}
	for n in names {
		r.index[n.to_upper()] = r.list.len - 1
	}
}

fn (r CommandRegistry) find(name string) ?Command {
	i := r.index[name.to_upper()] or { return none }
	return r.list[i]
}

fn (r CommandRegistry) all() []Command {
	return r.list
}

// standard_commands is the production wiring: every feature's commands.
fn standard_commands() CommandRegistry {
	mut r := CommandRegistry{}
	register_core_commands(mut r)
	register_room_commands(mut r)
	register_mail_commands(mut r)
	register_info_commands(mut r)
	register_fun_commands(mut r)
	register_account_commands(mut r)
	register_admin_commands(mut r)
	return r
}
