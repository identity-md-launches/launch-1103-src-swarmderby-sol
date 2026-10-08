import json, os, signal, threading, time, urllib.request
from playwright.sync_api import sync_playwright
exec(open('e2e/play.py').read().split('url=')[0])  # rpc(), miner, SHIM
HOUSE=int(os.environ['HOUSE_PID'])   # the running house service: paused for the whole draw window
url=f"file://{__import__('os').path.abspath(__import__('os').environ.get('SITE', '../swarm-derby-site/index.html'))}?network=local&rpc={RPC}&derby={A['derby']}&imd={A['imd']}"
with sync_playwright() as p:
    b=p.chromium.launch(); pg=b.new_page()
    errs=[]; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/cdn.tailwindcss.com/**', lambda r: r.abort()); pg.route('**/fonts.g*/**', lambda r: r.abort())
    pg.add_init_script(SHIM); pg.goto(url); pg.wait_for_timeout(300)
    pg.click('#walletBtn'); pg.wait_for_function("live.on && !live.busy", timeout=15000)
    pg.evaluate("buyLive('pack')"); pg.wait_for_function("!live.busy", timeout=20000)
    pg.click('#sessionBtn'); pg.wait_for_function("!live.busy && live.sessionActive", timeout=20000)
    before=pg.evaluate("turnsLeft"); print('turns before', before)
    os.kill(HOUSE, signal.SIGSTOP)
    try:
        t0=time.time()
        pg.evaluate("startMashPhase(); mashPower = 1; triggerPitchRelease(); pitchProgress = 1.0; executeSwing();")
        pg.wait_for_function("bannerText.textContent.includes('TURN RETURNED')", timeout=420000)
        print('refund after %.0fs' % (time.time()-t0), '| banner', pg.evaluate("bannerText.textContent.trim()"))
    finally:
        os.kill(HOUSE, signal.SIGCONT)
    pg.wait_for_function("!live.busy", timeout=20000)
    print('turns after', pg.evaluate("turnsLeft"), '(same as before:', pg.evaluate("turnsLeft") == before, ')', '| pending', pg.evaluate("JSON.parse(localStorage.getItem(storeKey('pending')) || '[]').length"))
    print('commentary', pg.evaluate("commentaryTicker.textContent.trim()"))
    print('errors', errs); stop=True; b.close()
