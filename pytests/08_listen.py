import asyncio, sys, datetime
from meshcore import MeshCore, EventType
def ts(): return datetime.datetime.now().strftime("%H:%M:%S")
async def main(port, secs=90):
    mc = await MeshCore.create_serial(port, 115200)
    if not mc: print("connect failed"); return
    await asyncio.sleep(2.5)
    r = await mc.commands.send_appstart()
    if r.type == EventType.ERROR: print("appstart error"); await mc.disconnect(); return
    print(f"connected: {r.payload.get('name')} @ {r.payload.get('radio_freq')} MHz")
    async def on_dm(ev):
        d = ev.payload
        print(f"[{ts()}] *** DM from {d.get('pubkey_prefix')}: {d.get('text')!r} ***")
    async def on_chan(ev):
        d = ev.payload
        print(f"[{ts()}] CH{d.get('channel_idx')}: {d.get('text')!r}")
    mc.subscribe(EventType.CONTACT_MSG_RECV, on_dm)
    mc.subscribe(EventType.CHANNEL_MSG_RECV, on_chan)
    await mc.start_auto_message_fetching()
    print(f"[{ts()}] LISTENING {secs}s --- send a DM from XeroKuhl now ...\n")
    await asyncio.sleep(secs)
    await mc.stop_auto_message_fetching()
    await mc.disconnect()
    print(f"\n[{ts()}] done listening.")
asyncio.run(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv)>2 else 90))
