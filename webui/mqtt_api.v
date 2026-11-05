module main

// MQTT settings as an API: the same settings, rules and daemon hand-off as the /mqtt page (mqtt_ui.v), for scripts. Reads answer JSON; writes take the
// page's form fields (curl -d report_url=... or --data-urlencode) and answer {"ok":true} or {"ok":false,"error":"..."} with 400. Secrets (broker
// passwords, the planner token) are never sent back, only whether they are set. Like the pages, this is reachable over the tailnet only.

import veb

fn jstr(s string) string {
	mut b := []u8{cap: s.len + 2}
	b << `"`
	for c in s {
		match c {
			`"` {
				b << `\\`
				b << `"`
			}
			`\\` {
				b << `\\`
				b << `\\`
			}
			`\n` {
				b << `\\`
				b << `n`
			}
			`\r` {
				b << `\\`
				b << `r`
			}
			`\t` {
				b << `\\`
				b << `t`
			}
			else {
				if c < 0x20 {
					b << `\\`.str().bytes()
					b << 'u00${c:02x}'.bytes()
				} else {
					b << c
				}
			}
		}
	}
	b << `"`
	return b.bytestr()
}

fn jbool(v bool) string {
	return if v { 'true' } else { 'false' }
}

fn mqtt_json(p MqttPage) string {
	mut brokers := []string{}
	for b in p.brokers {
		brokers << '{"id":${b.id},"name":${jstr(b.name)},"enabled":${jbool(b.enabled)},"host":${jstr(b.host)},"port":${b.port},"transport":${jstr(b.transport)},"path":${jstr(b.path)},"auth":${jstr(b.auth)},"username":${jstr(b.username)},"has_password":${jbool(b.has_password)},"audience":${jstr(b.audience)},"state":${jstr(b.state)},"last_error":${jstr(b.last_error)},"published":${b.published},"updated":${jstr(b.updated)}}'
	}
	r := p.report
	report := '{"enabled":${jbool(r.enabled)},"url":${jstr(r.url)},"has_token":${jbool(r.has_token)},"minutes":${r.minutes},"public_position":${jbool(r.public)},"lat":${jstr(r.lat)},"lon":${jstr(r.lon)},"state":${jstr(r.state)},"last_ok":${jstr(r.last_ok)}}'
	return '{"available":${jbool(p.available)},"enabled":${jbool(p.enabled)},"iata":${jstr(p.iata)},"state":${jstr(p.state)},"key":${jstr(p.key)},"rev":${jstr(p.rev)},"brokers":[${brokers.join(',')}],"report":${report}}'
}

fn api_result(mut ctx Context, err string) veb.Result {
	if err.len > 0 {
		ctx.res.set_status(.bad_request)
		return ctx.send_response_to_client('application/json', '{"ok":false,"error":${jstr(err)}}')
	}
	return ctx.send_response_to_client('application/json', '{"ok":true}')
}

@['/api/mqtt']
pub fn (app &App) api_mqtt(mut ctx Context) veb.Result {
	mut db := app.db() or { return api_result(mut ctx, 'db error') }
	defer { db.close() or {} }
	return ctx.send_response_to_client('application/json', mqtt_json(mqtt_load(mut db)))
}

@['/api/mqtt/settings'; post]
pub fn (app &App) api_mqtt_settings(mut ctx Context) veb.Result {
	mut db := app.db() or { return api_result(mut ctx, 'db error') }
	defer { db.close() or {} }
	return api_result(mut ctx, mqtt_save_settings(mut db, (ctx.form['enabled'] or { '' }) == '1', ctx.form['iata'] or { '' }))
}

@['/api/mqtt/report'; post]
pub fn (app &App) api_mqtt_report(mut ctx Context) veb.Result {
	mut db := app.db() or { return api_result(mut ctx, 'db error') }
	defer { db.close() or {} }
	return api_result(mut ctx, mqtt_save_report(mut db, ctx.form.clone()))
}

@['/api/mqtt/broker'; post]
pub fn (app &App) api_mqtt_broker_add(mut ctx Context) veb.Result {
	mut db := app.db() or { return api_result(mut ctx, 'db error') }
	defer { db.close() or {} }
	return api_result(mut ctx, mqtt_add_broker(mut db, ctx.form.clone()))
}

@['/api/mqtt/broker/update'; post]
pub fn (app &App) api_mqtt_broker_update(mut ctx Context) veb.Result {
	mut db := app.db() or { return api_result(mut ctx, 'db error') }
	defer { db.close() or {} }
	return api_result(mut ctx, mqtt_update_broker(mut db, (ctx.form['id'] or { '0' }).int(), ctx.form.clone()))
}

@['/api/mqtt/broker/toggle'; post]
pub fn (app &App) api_mqtt_broker_toggle(mut ctx Context) veb.Result {
	mut db := app.db() or { return api_result(mut ctx, 'db error') }
	defer { db.close() or {} }
	mqtt_toggle_broker(mut db, (ctx.form['id'] or { '0' }).int(), (ctx.form['enabled'] or { '' }) == '1')
	return api_result(mut ctx, '')
}

@['/api/mqtt/broker/delete'; post]
pub fn (app &App) api_mqtt_broker_delete(mut ctx Context) veb.Result {
	mut db := app.db() or { return api_result(mut ctx, 'db error') }
	defer { db.close() or {} }
	mqtt_delete_broker(mut db, (ctx.form['id'] or { '0' }).int())
	return api_result(mut ctx, '')
}
