module main

// Weather, news and the channel directory.

fn register_info_commands(mut r CommandRegistry) {
	r.add(['WX', 'WEATHER'], cmd_wx)
	r.add(['FORECAST', 'FC'], cmd_forecast)
	r.add(['ALERTS', 'ALERT'], cmd_alerts)
	r.add(['SPACEWX', 'SW', 'SPACE'], cmd_spacewx)
	r.add(['NEWS'], cmd_news)
	r.add(['CHANNELS', 'CHANDIR'], cmd_channels)
	r.add(['CHANADD'], cmd_chanadd)
}

fn cmd_wx(mut e Engine, mut sess Session, args string) string {
	return fetch_weather()
}

fn cmd_forecast(mut e Engine, mut sess Session, args string) string {
	days := if args.trim_space().len > 0 {
		args.trim_space().int()
	} else {
		forecast_default_days
	}
	return fetch_forecast(days)
}

fn cmd_alerts(mut e Engine, mut sess Session, args string) string {
	return fetch_alerts_report()
}

fn cmd_spacewx(mut e Engine, mut sess Session, args string) string {
	return fetch_spacewx()
}

fn cmd_news(mut e Engine, mut sess Session, args string) string {
	return e.fetch_news_fresh()
}

fn cmd_channels(mut e Engine, mut sess Session, args string) string {
	return e.channels_list()
}

fn cmd_chanadd(mut e Engine, mut sess Session, args string) string {
	return e.channel_add(mut sess, args)
}
