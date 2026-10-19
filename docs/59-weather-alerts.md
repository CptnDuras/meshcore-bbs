# 59 — NWS emergency weather alerts

The daemon polls `api.weather.gov/alerts/active?area=WY` every 5 minutes and keeps alerts whose
`geocode.SAME` includes Sheridan County (`056033`) or Johnson County (`056019`). Only `Actual` alerts
that have not expired are used (tests and cancellations are skipped).

- **Public channel (0):** every new matching alert (watch, advisory, warning, ...).
- **DMs:** Warning-level and above (event ends in "Warning" or "Emergency", or NWS severity `Extreme`) is
  also DMed to every node that has a BBS session, unless that user ran `CONFIG SET alerts off`.
- **Dedupe:** by event + counties (table `wx_alerts_sent`). An NWS update to a still-active alert is not
  re-sent; the key is forgotten 6 h after the alert leaves the feed.
- **`ALERTS` command:** shows what is active right now for the two counties.
- **Test mode (sysop):** `ALERTTEST` sends a sample Tornado Warning wrapped in a "*** TEST ***" pre-message and an "*** END OF TEST ***" post-message. Default goes to the requesting sysop by DM only; `ALERTTEST CHAN` posts to channel 0; `ALERTTEST ALL` is channel + every opted-in node.

Code: `bbs/alerts.v` (policy + formatting), `bbs/minijson.v` (small JSON reader; `json` is gone from V and
json2 crashed on FreeBSD), polling hook in `bbs/main.v`. Counties and timing are constants at the top of `alerts.v`.
