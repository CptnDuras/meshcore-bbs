module main

import os
import time
import meshcore

const default_port = '/dev/cuaU0'
const default_db = 'sqlite:meshbbs.db'

fn main() {
	port := if os.args.len > 1 { os.args[1] } else { default_port }
	db_cfg := if os.args.len > 2 { os.args[2] } else { default_db }

	// --- storage (pluggable) ---
	mut store := new_store(db_cfg) or {
		eprintln('store init failed: ${err}')
		exit(1)
	}
	store.migrate() or {
		// tables may already exist; that's fine
	}
	// seed a couple of default boards on first run
	store.ensure_board('general', 'General discussion') or {}
	store.ensure_board('swap', 'Buy / sell / trade') or {}

	mut engine := Engine{
		store:             store
		name:              'meshbbs'
		started:           time.now().unix()
		min_turn_interval: 3 // seconds between accepted turns per node (mesh self-defense)
		last_turn:         map[string]i64{}
	}

	// --- radio ---
	println('meshbbs starting on ${port} (db=${db_cfg}) ...')
	mut mc := meshcore.create_serial(port, 115200, false) or {
		eprintln('radio connect failed: ${err}')
		exit(1)
	}
	defer {
		mc.disconnect()
	}
	si := mc.send_appstart('meshbbs') or {
		eprintln('appstart failed: ${err}')
		exit(1)
	}
	println('BBS live as ${si.payload.name} @ ${si.payload.radio_freq} MHz. Waiting for callers...\n')

	// --- optional MQTT observer (off unless enabled in the web UI) ---
	// Identity comes from the radio; model/firmware are best-effort.
	mut mqtt_ident := MqttIdentity{
		origin:    si.payload.name
		origin_id: si.payload.public_key.to_upper()
	}
	if di := mc.send_device_query() {
		mqtt_ident.model = di.payload.model
		mqtt_ident.fw = di.payload.fw_version
	}
	mut mqtt := &MqttRuntime{
		ident:      mqtt_ident
		factory:    new_native_pipe
		key_loader: fn [mut mc] () !string {
			return mc.export_private_key()!.hex()
		}
	}
	// Every packet the radio hears is forwarded (a no-op unless MQTT is running).
	mc.subscribe(.log_rx_data, fn [mut mqtt] (ev meshcore.Event) {
		mqtt.on_packet(time.now().unix(), ev.payload.snr, ev.payload.rssi, ev.payload.data)
	})

	// Set this node's advertised friendly name so neighbours see 'MESHBBS'
	// (overridable via arg 4). Then advert once so the new name propagates.
	node_name := if os.args.len > 4 { os.args[4] } else { 'MESHBBS' }
	mc.set_name(node_name) or { eprintln('set node name failed: ${err}') }
	mc.send_advert(false) or { eprintln('startup advert failed: ${err}') }
	println('Node advertised name set to ${node_name}.')

	// Optional one-time public announcement (arg 3 == 'announce').
	// Sent by THIS process because the serial port is single-owner.
	if os.args.len > 3 && os.args[3] == 'announce' {
		msg := 'meshbbs is ONLINE! DM this node to access the BBS: register with "NEW <handle> <pass>", then explore. Send HELP once connected.'
		mc.send_chan_msg(0, msg) or { eprintln('announce failed: ${err}') }
		println('Announced on public channel 0.')
	}

	// handle each incoming DM as a BBS command turn
	handler := fn [mut engine, mut mc] (ev meshcore.Event) {
		sender := ev.payload.pubkey_prefix
		text := ev.payload.text
		// passive mesh-health: record this DM as observed traffic (SNR/path).
		engine.log_traffic('dm', sender, ev.payload.snr, int(ev.payload.path_len))
		println('[${sender}] > ${text}')

		// Hidden slash command: "/advert" triggers a real MeshCore self-advert
		// broadcast from this node. Handled HERE (not in the engine) because the
		// radio handle `mc` only exists in this closure, and it is intentionally
		// kept out of the engine's command surface + HELP so it stays hidden.
		trimmed := text.trim_space()
		low := trimmed.to_lower()
		if low == '/advert' || low.starts_with('/advert ') {
			flood := low.contains('flood')
			mc.send_advert(flood) or {
				eprintln('  advert failed: ${err}')
				engine.log_slash(sender, '/advert', 'error')
				mc.send_msg(sender, 'advert failed') or {}
				return
			}
			println('  [/advert] sent (flood=${flood}) for ${sender}')
			engine.log_slash(sender, '/advert', if flood { 'flood' } else { 'zero-hop' })
			reply_txt := if flood { 'Flood advert sent.' } else { 'Advert sent.' }
			mc.send_msg(sender, reply_txt) or { eprintln('  send failed: ${err}') }
			return
		}

		reply := engine.handle(sender, text)
		pages := paginate(reply)
		msgs, _, _ := burst(pages, 0)
		for m in msgs {
			mc.send_msg(sender, m) or {
				eprintln('  send failed: ${err}')
				break
			}
			// brief spacing so the radio isn't hammered back-to-back
			time.sleep(300 * time.millisecond)
		}
		println('  replied ${msgs.len} msg(s) to ${sender}')
	}
	mc.subscribe(.contact_msg_recv, handler)

	// Passive mesh-health capture: overheard adverts (traffic NOT directed at
	// this node) update the node-name map AND get logged as traffic. Adverts
	// carry the source public key; the prefix is its first 6 bytes.
	advert_cb := fn [mut engine] (ev meshcore.Event) {
		pk := ev.payload.public_key
		prefix := if pk.len >= 12 { pk[..12] } else { pk }
		engine.log_traffic('advert', prefix, ev.payload.snr, int(ev.payload.path_len))
		if ev.payload.adv_name.len > 0 {
			engine.save_node_name(prefix, ev.payload.adv_name, int(ev.payload.contact_type),
				i64(ev.payload.last_advert))
		}
		// Proactive store-and-forward: if this node's account has unread mail,
		// enqueue a rate-limited, notice-only DM (the daemon loop drains it).
		// Resolve the node's current handle from its session (handles the case
		// where the user CLAIMed a real handle); fall back to the auto handle.
		mut handle := 'node-${prefix}'
		if sess := engine.store.load_session(prefix) {
			if sess.handle.len > 0 {
				handle = sess.handle
			}
		}
		notice := engine.maybe_mail_notice(handle, time.now().unix())
		if notice.len > 0 {
			engine.store.enqueue_outbound(target_dm, prefix, notice) or {}
			println('[mail-notice] queued for ${prefix} (${handle})')
		}
	}
	mc.subscribe(.advertisement, advert_cb)

	// Overheard channel messages (public traffic) -> log for mesh health.
	chan_cb := fn [mut engine] (ev meshcore.Event) {
		engine.log_traffic('chan_msg', ev.payload.pubkey_prefix, ev.payload.snr, int(ev.payload.path_len))
	}
	mc.subscribe(.channel_msg_recv, chan_cb)

	// Contact auto-accept: when an unknown node advertises (NEW_CONTACT), add it
	// to the radio's contact book automatically so replies route without manual
	// approval. Also capture its name for the node-name map + log the event.
	newcontact_cb := fn [mut engine, mut mc] (ev meshcore.Event) {
		p := ev.payload
		prefix := if p.public_key.len >= 12 { p.public_key[..12] } else { p.pubkey_prefix }
		mc.accept_contact(p) or {
			eprintln('auto-accept failed for ${prefix}: ${err}')
			engine.log_traffic('new_contact_fail', prefix, p.snr, int(p.path_len))
			return
		}
		println('[auto-accept] added contact ${prefix} (${p.adv_name})')
		engine.log_traffic('new_contact', prefix, p.snr, int(p.path_len))
		if p.adv_name.len > 0 {
			engine.save_node_name(prefix, p.adv_name, int(p.contact_type), i64(p.last_advert))
		}
	}
	mc.subscribe(.new_contact, newcontact_cb)

	mc.start_auto_message_fetching()

	// contact_refresh syncs the radio's contact list into node_names. Called at
	// startup and every 15 minutes from the loop below.
	contact_refresh := fn [mut engine, mut mc] () {
		contacts := mc.get_contacts(0, 8000) or {
			eprintln('contact refresh failed: ${err}')
			return
		}
		mut n := 0
		for c in contacts {
			if c.pubkey_prefix.len > 0 && c.adv_name.len > 0 {
				engine.save_node_name(c.pubkey_prefix, c.adv_name, int(c.contact_type),
					i64(c.last_advert))
				n++
			}
		}
		println('[contacts] refreshed ${n} node name(s)')
	}
	// initial load
	contact_refresh()
	mut last_contact_sync := time.now().unix()
	contact_sync_interval := i64(15 * 60) // 15 minutes

	// Periodic self-advert with flood routing so the whole mesh keeps a fresh
	// route to MESHBBS (not just direct neighbours). The startup advert above is
	// zero-hop; this one floods every 30 min. Sent by THIS process because the
	// serial port is single-owner.
	advert_interval := i64(30 * 60) // 30 minutes
	mut last_advert := time.now().unix() // startup advert already sent above

	// --- all scheduling is DB-backed (scheduled_messages) ---
	// Seed the standing daily broadcasts as DB rows if they don't already exist,
	// so they are visible/editable in the web UI. Idempotent: keyed by
	// (source, daily_minute), so restarts never duplicate them. Their content is
	// generated live at send time via the `source` field (see resolve_source).
	seed_schedule(mut engine, src_digest, 7 * 60, 'Morning digest') // 07:00 wx+spacewx+news
	seed_schedule(mut engine, src_news, 7 * 60 + 5, 'Local news') // 07:05
	seed_schedule(mut engine, src_fortune, 12 * 60, 'Daily fortune') // 12:00

	// Local timezone offset (secs) so daily schedules fire at local wall-clock time.
	tz_offset := i64(time.offset())
	mut last_alert_poll := i64(0)

	for {
		now := time.now().unix()

		// MQTT observer: reconcile the publisher with the web-UI configuration.
		mqtt.tick(now, mut engine.store)

		// NWS emergency alerts for Sheridan / Johnson county: channel + DMs.
		if now - last_alert_poll >= alerts_poll_secs {
			last_alert_poll = now
			engine.poll_alerts(now)
		}

		// Test-alert clicks from the web UI.
		engine.handle_alert_requests()

		// Refresh the node-name map from the radio's contact list every 15 min.
		if now - last_contact_sync >= contact_sync_interval {
			contact_refresh()
			last_contact_sync = now
		}

		// Periodic flood advert every 30 min so the mesh keeps a fresh route.
		if now - last_advert >= advert_interval {
			mc.send_advert(true) or { eprintln('periodic flood advert failed: ${err}') }
			last_advert = now
			println('[advert] periodic flood advert sent')
		}

		// Evaluate DB-backed scheduled messages: enqueue any that are due,
		// resolving dynamic sources (wx/news/fortune/digest) at send time.
		mod := minute_of_day(now + tz_offset)
		for sm in engine.store.list_scheduled(200) {
			if scheduled_due(sm, now, mod) {
				text := engine.resolve_source(sm.source, sm.text)
				if text.len == 0 {
					// source produced nothing (e.g. feed down) — skip, retry next due
					engine.store.mark_scheduled_run(sm.id, now) or {}
					continue
				}
				engine.store.enqueue_outbound(sm.target_kind, sm.target, text) or {
					eprintln('enqueue scheduled #${sm.id} failed: ${err}')
					continue
				}
				engine.store.mark_scheduled_run(sm.id, now) or {}
				if scheduled_is_onetime(sm) {
					engine.store.set_scheduled_enabled(sm.id, false) or {}
				}
				println('[sched] queued #${sm.id} (${sm.source}) -> ${sm.target_kind}:${sm.target}')
			}
		}

		// Drain the outbound queue (the daemon is the sole owner of the radio).
		for om in engine.store.pending_outbound(20) {
			pages := paginate(om.text)
			out_msgs, _, _ := burst(pages, 0)
			mut ok := true
			for m in out_msgs {
				if om.target_kind == target_dm {
					mc.send_msg(om.target, m) or {
						eprintln('  outbound dm failed: ${err}')
						ok = false
						break
					}
				} else {
					ch := u8(om.target.int())
					mc.send_chan_msg(ch, m) or {
						eprintln('  outbound chan failed: ${err}')
						ok = false
						break
					}
				}
				time.sleep(500 * time.millisecond)
			}
			if ok {
				engine.store.mark_outbound_sent(om.id) or {}
				println('[outbound] sent #${om.id} -> ${om.target_kind}:${om.target}')
			}
		}

		time.sleep(1 * time.second)
	}
}

// seed_schedule inserts a standing daily broadcast as a DB row if one with the
// same (source, daily_minute) does not already exist. Idempotent so restarts
// never create duplicates. These rows are then visible/editable in the web UI.
fn seed_schedule(mut engine Engine, source string, daily_minute int, label string) {
	if engine.store.count_scheduled_by_source(source, daily_minute) > 0 {
		return
	}
	engine.store.add_scheduled(ScheduledMessage{
		target_kind:  target_chan
		target:       '0'
		text:         label
		source:       source
		sched_kind:   sched_daily
		daily_minute: daily_minute
		enabled:      true
	}) or { eprintln('seed schedule (${source}) failed: ${err}') }
	println('[seed] created ${source} daily schedule @ ${daily_minute / 60:02d}:${daily_minute % 60:02d}')
}
