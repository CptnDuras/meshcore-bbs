import asyncio, sys
from meshcore import MeshCore, EventType

async def main(port):
    mc = await MeshCore.create_serial(port, 115200)
    if not mc:
        print("connect failed"); return
    await asyncio.sleep(2.5)
    r = await mc.commands.send_appstart()
    if r.type == EventType.ERROR:
        print("appstart error:", r.payload); await mc.disconnect(); return
    print(f"connected: {r.payload.get('name')} @ {r.payload.get('radio_freq')} MHz\n")

    print("=== contacts ===")
    res = await mc.commands.get_contacts()
    contacts = res.payload if res.type != EventType.ERROR else {}
    for k, c in contacts.items():
        print(f"  {c.get('adv_name')!r}  key={k[:12]}...")
    if not contacts:
        print("  (none yet)")

    print("\n=== draining message queue ===")
    got = 0
    for i in range(50):
        m = await mc.commands.get_msg(timeout=5)
        if m is None or m.type == EventType.NO_MORE_MSGS:
            break
        if m.type in (EventType.CONTACT_MSG_RECV, EventType.CHANNEL_MSG_RECV):
            got += 1
            d = m.payload
            kind = "DM" if m.type == EventType.CONTACT_MSG_RECV else f"CH{d.get('channel_idx')}"
            print(f"  [{kind}] from {d.get('pubkey_prefix')}: {d.get('text')!r}")
        else:
            print(f"  ({m.type}: {m.payload})")
    print(f"\nretrieved {got} message(s)")
    await mc.disconnect()

asyncio.run(main(sys.argv[1]))
