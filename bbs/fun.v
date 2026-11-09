module main

import os
import rand

// Flavor / "door" commands common to MeshCore & Meshtastic BBS systems
// (TC2-BBS fortune teller; meshcore-bot dice/roll/magic8/joke).
//
// Design: the command entry points do the RNG/IO; the string-shaping logic is
// split into pure helpers so it can be unit-tested deterministically.

// Path to an optional fortunes file (one fortune per line). If missing, we fall
// back to a small embedded list so the command always works.
const fortunes_path = 'fortunes.txt'

const embedded_fortunes = [
	'The mesh provides.',
	'A packet in the hand is worth two in the repeater.',
	'You will make contact with a distant node today.',
	'Low SNR now; clear skies ahead.',
	'Reply hazy, try boosting your antenna.',
	'Off-grid, but never off-community.',
	'73 and good DX.',
	'The best time to deploy a node was 20 years ago. The second best time is now.',
]

const magic8_answers = [
	'It is certain.',
	'Without a doubt.',
	'Yes, definitely.',
	'Most likely.',
	'Signs point to yes.',
	'Reply hazy, try again.',
	'Ask again later.',
	'Cannot predict now.',
	"Don't count on it.",
	'My sources say no.',
	'Very doubtful.',
	'Outlook not so good.',
	'As I see it, yes.',
	'You may rely on it.',
	'Yes.',
	'Outlook good.',
	'Better not tell you now.',
	'Concentrate and ask again.',
	'The mesh says yes.',
	'The repeater is silent on this.',
	'Signal too weak to tell.',
	'Ask again after your next QSO.',
	'The packet was dropped. Retry.',
	'ACK.',
	'NACK.',
	'CQ CQ — the answer is out there.',
	'Definitely maybe.',
	'Static suggests no.',
	'A strong yes on all bands.',
	'Check your antenna, then ask again.',
]

const jokes = [
	'Why do hams make bad comedians? Their timing is always off-frequency.',
	'I told a LoRa joke. It took three hops to land.',
	"What is a node's favorite music? Heavy mesh.",
	'I would tell you a UDP joke, but you might not get it.',
	'My antenna broke up with me. Said we had no connection.',
	'Why did the packet cross the mesh? To get to the other node.',
	'I have a great TCP joke. Want me to keep repeating it until you get it?',
	'Two antennas got married. The wedding was terrible, but the reception was great.',
	'Why was the radio operator calm? Because he knew how to keep his frequency.',
	'I tried a mesh networking joke, but it only worked when everyone repeated it.',
	'Why did the node go to therapy? Too many unresolved connections.',
	'What do you call a node that never stops talking? A repeater.',
	'My packets have abandonment issues. They keep getting dropped.',
	"Why don't hams play hide and seek? Good luck hiding when you keep transmitting your location.",
	'A photon checks into a hotel. Bellhop: "Any luggage?" Photon: "No, I\'m traveling light."',
	'Why did the LoRa packet feel important? Low data rate, high self-esteem.',
	'I wanted to tell an antenna joke, but I could not find the right frequency.',
	"What is a mesh node's life motto? When one path fails, find another.",
	'Why did the battery join the mesh? It wanted to stay charged up socially.',
	'RF engineers do it with high frequency and low noise.',
	'Why are repeaters bad at secrets? They tell everyone, twice.',
	'My radio has commitment issues. It keeps changing channels.',
	'What did the router say to the doctor? "It hurts when IP."',
	'Why did the ham radio operator get kicked out of the library? Too much broadcasting.',
	'The mesh had a party. It was a real broadcast storm.',
	'How many nodes does it take to change a bulb? None — they just route around the dark.',
	'Why was the SNR sad? Nobody appreciated its quality time.',
	'A duplicate packet walks into a bar. A duplicate packet walks into a bar.',
	'Why do meshers make good friends? They always find a path to you.',
	'I asked my node for space. Now it only replies zero-hop.',
]

// --- FORTUNE ---

fn (mut e Engine) fortune() string {
	list := load_fortunes()
	if list.len == 0 {
		return 'No fortunes available.'
	}
	idx := rand.intn(list.len) or { 0 }
	return list[idx]
}

// load_fortunes reads fortunes.txt (one per line, skipping blanks and #
// comments); falls back to the embedded list if the file is absent/empty.
fn load_fortunes() []string {
	if os.exists(fortunes_path) {
		content := os.read_file(fortunes_path) or { return embedded_fortunes.clone() }
		parsed := parse_fortunes(content)
		if parsed.len > 0 {
			return parsed
		}
	}
	return embedded_fortunes.clone()
}

// parse_fortunes turns file content into a list. Pure -> unit testable.
fn parse_fortunes(content string) []string {
	mut out := []string{}
	for raw in content.split_into_lines() {
		line := raw.trim_space()
		if line.len == 0 || line.starts_with('#') {
			continue
		}
		out << line
	}
	return out
}

// --- DICE / ROLL ---

fn (mut e Engine) roll(args string) string {
	spec := args.trim_space()
	n, sides := parse_dice(spec) or { return 'Usage: ROLL <count>d<sides> (e.g. 2d6)' }
	mut total := 0
	mut rolls := []string{}
	for _ in 0 .. n {
		r := rand.intn(sides) or { 0 } + 1
		total += r
		rolls << r.str()
	}
	if n == 1 {
		return 'Rolled d${sides}: ${total}'
	}
	return 'Rolled ${n}d${sides}: ${rolls.join('+')} = ${total}'
}

// parse_dice parses an NdM spec into (count, sides). Defaults: empty -> 1d6.
// Bounds: 1..20 dice, 2..1000 sides. Pure -> unit testable.
fn parse_dice(spec string) ?(int, int) {
	s := spec.to_lower().trim_space()
	if s.len == 0 {
		return 1, 6
	}
	if s.contains('d') {
		parts := s.split('d')
		if parts.len != 2 {
			return none
		}
		count := if parts[0].len == 0 { 1 } else { parts[0].int() }
		sides := parts[1].int()
		if count < 1 || count > 20 || sides < 2 || sides > 1000 {
			return none
		}
		return count, sides
	}
	// bare number -> that many sides, single die
	sides := s.int()
	if sides < 2 || sides > 1000 {
		return none
	}
	return 1, sides
}

// --- 8BALL ---

fn (mut e Engine) magic8(args string) string {
	if args.trim_space().len == 0 {
		return 'Ask the 8-ball a question: 8BALL <question>'
	}
	idx := rand.intn(magic8_answers.len) or { 0 }
	return '8-ball: ${magic8_answers[idx]}'
}

// --- JOKE ---

fn (mut e Engine) joke() string {
	idx := rand.intn(jokes.len) or { 0 }
	return jokes[idx]
}
