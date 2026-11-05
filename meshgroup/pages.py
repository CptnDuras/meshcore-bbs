"""The pages the list serves. Everything that came from a person goes through html.escape."""
from html import escape as h

STYLE = """body{font:16px/1.5 system-ui,sans-serif;max-width:34rem;margin:2rem auto;padding:0 1rem;color:#1d2a30;background:#f6f4ef}
h1{font-size:1.5rem}input{font:inherit;padding:.4rem;width:100%;box-sizing:border-box;margin:.2rem 0 .8rem}
button{font:inherit;padding:.5rem 1.2rem;background:#b5541c;color:#fff;border:0;border-radius:4px;cursor:pointer}
.hp{position:absolute;left:-9999px}small{color:#5a6a72}"""


def page(title, body):
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{h(title)}</title><style>{STYLE}</style></head><body>{body}</body></html>')


def home(cfg):
    return page(cfg.list_name, f"""<h1>{h(cfg.list_name)}</h1>
<p>A small mailing list for people on the mesh. Anyone on it can write to <strong>{h(cfg.list_address)}</strong>
and the message goes to everyone else on the list.</p>
<form method="post" action="/subscribe">
<label>Your email<input name="email" type="email" required maxlength="254" autocomplete="email"></label>
<label>Your name (optional)<input name="name" maxlength="60" autocomplete="name"></label>
<div class="hp" aria-hidden="true"><label>Leave this empty<input name="website" tabindex="-1" autocomplete="off"></label></div>
<button type="submit">Join the list</button>
</form>
<p><small>We send a message with a link to confirm, and nothing else until you click it. Every message has a link to leave.</small></p>""")


def notice(cfg, title, text):
    return page(title, f'<h1>{h(title)}</h1><p>{h(text)}</p><p><a href="/">Back</a></p>')


def confirm(cfg, path, address, token):
    verb = 'Join the list' if path == '/confirm' else 'Leave the list'
    return page(verb, f"""<h1>{h(verb)}</h1><p>{h(address)}</p>
<form method="post" action="{h(path)}"><input type="hidden" name="e" value="{h(address)}"><input type="hidden" name="t" value="{h(token)}">
<button type="submit">{h(verb)}</button></form>""")
