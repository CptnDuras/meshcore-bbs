import asyncio, sys, datetime
from meshcore import MeshCore, EventType

def ts(): return datetime.datetime.now().strftime("%H:%M:%S")

async def main(port, listen_secs=60):
    mc = None
    for attempt in range(1, 5):
        try:
            mc = await MeshCore.create_serial(port, 115200)
        except Exception as e:
            print(f"connect attempt {attempt}: {e}")
            mc = None
        if mc:
            await asyncio.sleep(2.5)  # give ESP32 time to finish booting after DTR reset
            r = await mc.commands.send_appstart()
            if r.type != EventType.ERROR:
                break
            print(f"attempt {attempt}: appstart no-response, retrying...")
            try: await mc.disconnect()
            except Exception: pass
            mc = None
        await asyncio.sleep(2.0)
    if not mc:
        print("Could not get a working connection after retries."); return

    p = r.payload
    print(f"Node {p['name']} on {p['radio_freq']} MHz SF{p['radio_sf']}\n")

    async def on_chan(ev):
        d = ev.payload; print(f"[{ts()}] CHANNEL {d.get('channel_idx')}: {d.get('text')!r}")
    async def on_dm(ev):
        d = ev.payload; print(f"[{ts()}] DM from {d.get('pubkey_prefix')}: {d.get('text')!r}")
    async def on_adv(ev):
        print(f"[{ts()}] advert heard from {str(ev.payload)[:60]}")
    mc.subscribe(EventType.CHANNEL_MSG_RECV, on_chan)
    mc.subscribe(EventType.CONTACT_MSG_RECV, on_dm)
    mc.subscribe(EventType.ADVERTISEMENT, on_adv)
    await mc.start_auto_message_fetching()

    msg = "Hello mesh from meshbbs test node!"
    print(f"[{ts()}] sending to public channel 0: {msg!r}")
    res = await mc.commands.send_chan_msg(0, msg)
    print(f"[{ts()}]   send result: {res.type}\n")
    print(f"Listening {listen_secs}s ...\n")
    await asyncio.sleep(listen_secs)

    await mc.stop_auto_message_fetching()
    await mc.disconnect()
    print("\nDone listening.")

asyncio.run(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 60))
