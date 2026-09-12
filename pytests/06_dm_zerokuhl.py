import asyncio, sys, datetime
from meshcore import MeshCore, EventType

def ts(): return datetime.datetime.now().strftime("%H:%M:%S")

async def main(port, target="ZeroKuhl", listen_secs=60):
    mc = await MeshCore.create_serial(port, 115200)
    if not mc:
        print("connect failed"); return
    await asyncio.sleep(2.5)  # settle after reset; single connection, no reconnect
    r = await mc.commands.send_appstart()
    if r.type == EventType.ERROR:
        print("appstart error:", r.payload); await mc.disconnect(); return
    print(f"This node: {r.payload.get('name')} @ {r.payload.get('radio_freq')} MHz\n")

    # live handlers
    async def on_dm(ev):
        d = ev.payload
        print(f"[{ts()}] *** DM from {d.get('pubkey_prefix')}: {d.get('text')!r} ***")
    async def on_adv(ev):
        print(f"[{ts()}] advert heard: {str(ev.payload)[:70]}")
    async def on_new(ev):
        print(f"[{ts()}] NEW CONTACT: {str(ev.payload)[:80]}")
    mc.subscribe(EventType.CONTACT_MSG_RECV, on_dm)
    mc.subscribe(EventType.ADVERTISEMENT, on_adv)
    mc.subscribe(EventType.NEW_CONTACT, on_new)
    await mc.start_auto_message_fetching()

    # advertise ourselves so ZeroKuhl can learn us
    print(f"[{ts()}] sending flood advert so {target} can hear us ...")
    await mc.commands.send_advert(flood=True)
    await asyncio.sleep(2)

    # refresh contacts
    res = await mc.commands.get_contacts()
    contacts = res.payload if res.type != EventType.ERROR else {}
    print(f"\n[{ts()}] known contacts ({len(contacts)}):")
    for k, c in contacts.items():
        print(f"   - {c.get('adv_name')!r}  key={k[:12]}...")

    target_contact = mc.get_contact_by_name(target)
    if target_contact:
        print(f"\n[{ts()}] found {target} — sending DM ...")
        s = await mc.commands.send_msg(target_contact, "Private test from meshbbs node. Reply?")
        print(f"[{ts()}]   send result: {s.type} {getattr(s,'payload',None)}")
    else:
        print(f"\n[{ts()}] {target} NOT in contacts yet.")
        print(f"[{ts()}] --> On your phone, have {target} send an advert (share/advertise),")
        print(f"[{ts()}]     then it should appear above / as NEW CONTACT. We're listening...")

    print(f"\nListening {listen_secs}s (DM ZeroKuhl from your phone to see it arrive) ...\n")
    await asyncio.sleep(listen_secs)
    await mc.stop_auto_message_fetching()
    await mc.disconnect()
    print("\nDone.")

asyncio.run(main(sys.argv[1],
                 sys.argv[2] if len(sys.argv) > 2 else "ZeroKuhl",
                 int(sys.argv[3]) if len(sys.argv) > 3 else 60))
