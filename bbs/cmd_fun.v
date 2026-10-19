module main

// Games, oneliners, bulletins and polls.

fn register_fun_commands(mut r CommandRegistry) {
	r.add(['FORTUNE', 'QOTD'], cmd_fortune)
	r.add(['ROLL', 'DICE'], cmd_roll)
	r.add(['8BALL', 'MAGIC8'], cmd_8ball)
	r.add(['JOKE'], cmd_joke)
	r.add(['ONELINER', 'O'], cmd_oneliner)
	r.add(['BULLETIN', 'BULLETINS', 'B'], cmd_bulletin)
	r.add(['POLL', 'POLLS'], cmd_poll)
	r.add(['VOTE', 'V'], cmd_vote)
	r.add(['RESULTS'], cmd_results)
	r.add(['POLLCLOSE'], cmd_pollclose)
}

fn cmd_fortune(mut e Engine, mut sess Session, args string) string {
	return e.fortune()
}

fn cmd_roll(mut e Engine, mut sess Session, args string) string {
	return e.roll(args)
}

fn cmd_8ball(mut e Engine, mut sess Session, args string) string {
	return e.magic8(args)
}

fn cmd_joke(mut e Engine, mut sess Session, args string) string {
	return e.joke()
}

fn cmd_oneliner(mut e Engine, mut sess Session, args string) string {
	return e.oneliner(mut sess, args)
}

fn cmd_bulletin(mut e Engine, mut sess Session, args string) string {
	return e.bulletins()
}

fn cmd_poll(mut e Engine, mut sess Session, args string) string {
	return e.polls(mut sess, args)
}

fn cmd_vote(mut e Engine, mut sess Session, args string) string {
	return e.vote(mut sess, args)
}

fn cmd_results(mut e Engine, mut sess Session, args string) string {
	return e.poll_results(args)
}

fn cmd_pollclose(mut e Engine, mut sess Session, args string) string {
	return e.close_poll_cmd(mut sess, args)
}
