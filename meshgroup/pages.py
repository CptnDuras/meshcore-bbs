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


# ---- the owner's pages (console.py) ----

NOINDEX = '<meta name="robots" content="noindex">'


def admin_notice(title, text):
    return page(title, f'{NOINDEX}<h1>{h(title)}</h1><p>{h(text)}</p>')


def admin_login(message=''):
    note = f'<p><strong>{h(message)}</strong></p>' if message else ''
    return page('Owner login', f"""{NOINDEX}<h1>Owner login</h1>{note}
<form method="post" action="/admin/login"><label>Password<input name="password" type="password" required autocomplete="current-password"></label>
<button type="submit">Log in</button></form>""")


def _row(m, csrf):
    e, status = h(m['email']), m.get('status', '')

    def button(path, label):
        return (f'<form method="post" action="/admin/{path}" class="row"><input type="hidden" name="c" value="{h(csrf)}">'
                f'<input type="hidden" name="e" value="{e}"><button type="submit">{label}</button></form>')

    block = button('unblock', 'Unblock') if status == 'blocked' else button('block', 'Block')
    return f'<tr><td>{e}</td><td>{h(m.get("name", ""))}</td><td>{h(status)}</td><td>{button("remove", "Remove")} {block}</td></tr>'


def admin_page(cfg, members, csrf, message=''):
    active = sum(m.get('status') == 'active' for m in members)
    note = f'<p class="msg">{h(message)}</p>' if message else ''
    rows = ''.join(_row(m, csrf) for m in members) or '<tr><td colspan="4">No one yet.</td></tr>'
    return page(f'{cfg.list_name} owner', f"""{NOINDEX}<style>body{{max-width:52rem}}table{{border-collapse:collapse;width:100%}}
td,th{{text-align:left;padding:.3rem .5rem;border-bottom:1px solid #d8d2c4}}.row{{display:inline}}.row button{{padding:.15rem .6rem;font-size:.85rem}}
textarea{{font:inherit;width:100%;min-height:7rem;box-sizing:border-box}}.msg{{background:#e8f0e4;padding:.5rem .8rem;border-radius:4px}}</style>
<h1>{h(cfg.list_name)}: owner</h1>{note}
<p>{active} active, {len(members)} in all. The list address is <strong>{h(cfg.list_address)}</strong>.</p>
<h2>Add people</h2>
<form method="post" action="/admin/add"><input type="hidden" name="c" value="{h(csrf)}">
<label>One a line: an address, an address and a name, or Name &lt;address&gt;. They go on the list at once, with no confirmation message.
<textarea name="people" required></textarea></label><button type="submit">Add</button></form>
<h2>People</h2><table><tr><th>Address</th><th>Name</th><th>State</th><th></th></tr>{rows}</table>
<form method="post" action="/admin/logout"><input type="hidden" name="c" value="{h(csrf)}"><p><button type="submit">Log out</button></p></form>""")
