#!/usr/bin/env python3
"""End-to-end Touch Bar check: digitizer in, tiny-dfr keys out.

Watches both ends at once and says which link, if any, is broken.
No root needed. Run it in your own terminal so you can see the prompt:

    python3 watch-endtoend.py
"""
import os, select, struct, sys, time

def find(pred):
    for e in sorted(os.listdir('/sys/class/input')):
        if not e.startswith('event'):
            continue
        try:
            name = open(f'/sys/class/input/{e}/device/name').read().strip()
        except OSError:
            continue
        if pred(name):
            return f'/dev/input/{e}', name
    return None, None

dig_node, dig_name = find(lambda n: 'iBridge Touchpad' in n or ' Touch Bar' in n or 'T1 Controller Touchpad' in n)
dfr_node, dfr_name = find(lambda n: n.startswith('Dynamic Function Row'))

if not dig_node:
    sys.exit('no Touch Bar digitizer input device found')
if not dfr_node:
    sys.exit('tiny-dfr virtual input device not found - is tiny-dfr running?')

print(f'digitizer : {dig_node}  "{dig_name}"')
print(f'tiny-dfr  : {dfr_node}  "{dfr_name}"')

fds = {}
for node, label in ((dig_node, 'DIGITIZER'), (dfr_node, 'TINY-DFR')):
    try:
        fds[os.open(node, os.O_RDONLY | os.O_NONBLOCK)] = label
    except OSError as exc:
        sys.exit(f'cannot open {node}: {exc}')

KEYS = {1: 'ESC', 59: 'F1', 60: 'F2', 61: 'F3', 62: 'F4', 63: 'F5', 64: 'F6',
        65: 'F7', 66: 'F8', 67: 'F9', 68: 'F10', 87: 'F11', 88: 'F12',
        113: 'MUTE', 114: 'VOLUMEDOWN', 115: 'VOLUMEUP', 163: 'NEXTSONG',
        164: 'PLAYPAUSE', 165: 'PREVIOUSSONG', 224: 'BRIGHTNESSDOWN',
        225: 'BRIGHTNESSUP', 229: 'KBDILLUMDOWN', 230: 'KBDILLUMUP', 464: 'FN'}

SECS = 25
print(f'\n>>> TAP AND SLIDE THE TOUCH BAR NOW — {SECS} seconds <<<')
print('    hit Esc, a media key, and slide across the bar\n')

fmt = 'llHHi'
size = struct.calcsize(fmt)
end = time.time() + SECS
count = {'DIGITIZER': 0, 'TINY-DFR': 0}
shown = 0
last_tick = 0

while time.time() < end:
    remaining = int(end - time.time())
    if remaining != last_tick and remaining % 5 == 0:
        last_tick = remaining
        print(f'    ...{remaining}s left  (digitizer {count["DIGITIZER"]}, keys {count["TINY-DFR"]})')
    ready, _, _ = select.select(list(fds), [], [], 0.5)
    for fd in ready:
        try:
            data = os.read(fd, size * 64)
        except OSError:
            continue
        src = fds[fd]
        for i in range(0, len(data) - size + 1, size):
            _, _, etype, code, value = struct.unpack(fmt, data[i:i + size])
            if etype == 0:
                continue
            count[src] += 1
            interesting = (src == 'TINY-DFR' and etype == 1) or (etype == 3 and code == 57)
            if interesting and shown < 40:
                shown += 1
                if etype == 1:
                    print(f'  [{src}] KEY {KEYS.get(code, code)} '
                          f'{"press" if value else "release"}')
                else:
                    print(f'  [{src}] new contact (tracking id {value})')

print()
for k, n in count.items():
    print(f'  {k}: {n} events')

dig, dfr = count['DIGITIZER'], count['TINY-DFR']
print()
if dig and dfr:
    print('VERDICT: END TO END WORKING — touch reaches the kernel and tiny-dfr emits keys.')
elif dig:
    print('VERDICT: digitizer OK, tiny-dfr emits nothing.')
    print('         The kernel half works; the userspace link is the problem.')
else:
    print('VERDICT: no touch events at all.')
    print('         Either nothing was tapped, or the digitizer stopped reporting.')
