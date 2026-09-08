#!/bin/bash
# Health check for the T1 Touch Bar stack. Read-only; safe to run any time,
# and the first thing to run after a kernel, systemd or omarchy update.
#
#   bash doctor.sh          (some checks need root for full detail)
set -u

PASS=0; WARN=0; FAIL=0
ok()   { printf "  \033[32mok\033[0m    %s\n" "$*"; PASS=$((PASS+1)); }
warn() { printf "  \033[33mwarn\033[0m  %s\n" "$*"; WARN=$((WARN+1)); }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$*"; FAIL=$((FAIL+1)); }
sec()  { echo; echo "== $* =="; }

USB=""
for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor")" = 05ac ] && [ "$(cat "$d/idProduct")" = 8600 ] && USB=$d
done

sec "hardware"
if [ -n "$USB" ]; then
    ok "iBridge 05ac:8600 at $(basename "$USB")"
    CFG=$(cat "$USB/bConfigurationValue")
    [ "$CFG" = 2 ] && ok "USB configuration 2 (has the DFR display interface)" \
                   || bad "USB configuration $CFG - the panel cannot light (need 2)"
else
    bad "no 05ac:8600 iBridge found - is this a T1 Mac?"
fi

sec "kernel side"
if dkms status 2>/dev/null | grep -q '^appletbdrm-t1.*installed'; then
    ok "DKMS appletbdrm-t1 installed for $(uname -r)"
else
    bad "DKMS appletbdrm-t1 NOT installed for $(uname -r) - run: sudo dkms autoinstall"
fi
modinfo appletbdrm 2>/dev/null | grep -q 'p8600' \
    && ok "appletbdrm matches 05ac:8600" \
    || bad "appletbdrm does not match 05ac:8600 - the DKMS build is stock, not patched"
modinfo hid-appletb-bl 2>/dev/null | grep -q 'p00008600' \
    && ok "hid-appletb-bl matches 05ac:8600" \
    || bad "hid-appletb-bl does not match 05ac:8600"

# MT_CLS_APPLE_TOUCHBAR must still be what touchbar-t1-setup will write.
KO=$(modinfo -n hid-multitouch 2>/dev/null)
MT=$(python3 - "$KO" 2>/dev/null <<'PY'
import re, subprocess, sys
p = sys.argv[1]
d = (subprocess.run(['zstd','-dc',p], capture_output=True).stdout
     if p.endswith('.zst') else open(p,'rb').read())
pat = bytes.fromhex('03000000')+bytes.fromhex('ac050000')+bytes.fromhex('02830000')
m = re.search(re.escape(pat), d)
if m: print(f"{int.from_bytes(d[m.start()+16:m.start()+24],'little'):x}")
PY
)
if [ -n "$MT" ]; then
    ok "hid-multitouch carries MT_CLS_APPLE_TOUCHBAR (0x$MT)"
    [ "$MT" = 114 ] || warn "value changed from 0x114 - setup reads it at runtime, so this is fine"
else
    bad "hid-multitouch has no Apple Touch Bar class - kernel too old (need >= 6.15)"
fi

sec "bindings"
if [ -n "$USB" ]; then
    D=$(readlink "$USB:2.3/driver" 2>/dev/null | xargs -r basename)
    [ "$D" = appletbdrm ] && ok "DFR display bound to appletbdrm" \
                          || bad "DFR display bound to ${D:-nothing}"
    DIG=$(basename "$(ls -d "$USB:2.2"/0003:* 2>/dev/null | head -1)")
    D=$(readlink "/sys/bus/hid/devices/$DIG/driver" 2>/dev/null | xargs -r basename)
    [ "$D" = hid-multitouch ] && ok "digitizer bound to hid-multitouch" \
                              || bad "digitizer bound to ${D:-nothing} - touch will not work"
fi
[ -e /sys/class/backlight/appletb_backlight/brightness ] \
    && ok "appletb_backlight present (brightness $(cat /sys/class/backlight/appletb_backlight/brightness))" \
    || bad "appletb_backlight missing - tiny-dfr refuses to start without it"

sec "input"
FOUND=0
for e in /sys/class/input/event*; do
    case "$(cat "$e/device/name" 2>/dev/null)" in *iBridge*Touchpad*|*Touch\ Bar*|*T1\ Controller\ Touchpad*)
        FOUND=1
        P=$(cat "$e/device/properties")
        [ "$((0x$P & 2))" -ne 0 ] 2>/dev/null && ok "$(basename "$e") has INPUT_PROP_DIRECT" \
            || bad "$(basename "$e") lacks INPUT_PROP_DIRECT (PROP=$P) - libinput will treat it as a touchpad"
        S=$(udevadm info "/dev/input/$(basename "$e")" 2>/dev/null | grep -oP 'ID_SEAT=\K.*')
        [ "$S" = seat-touchbar ] && ok "digitizer ID_SEAT=seat-touchbar" \
            || bad "digitizer ID_SEAT=${S:-unset} - tiny-dfr will not see it"
        ;;
    esac
done
[ "$FOUND" = 1 ] || bad "no Touch Bar input device"

sec "seat / lockout canaries"
SEATS=$(loginctl list-seats 2>/dev/null | grep -cE '^seat')
[ "$SEATS" = 1 ] && ok "logind has exactly one seat (seat0)" \
                 || bad "logind has $SEATS seats - a synthesised seat crash-loops the display manager"
for c in /sys/class/drm/card[0-9]; do
    drv=$(readlink -f "$c/device/driver" 2>/dev/null | xargs -r basename)
    tags=$(udevadm info "$c" 2>/dev/null | grep -oP 'CURRENT_TAGS=\K.*')
    case "$drv" in
        appletbdrm) case "$tags" in *master-of-seat*)
                bad "$(basename "$c") (appletbdrm) is master-of-seat - the compositor will grab the panel";;
            *)  ok "$(basename "$c") (appletbdrm) is not a seat master";; esac ;;
        i915|amdgpu|nouveau|nvidia) case "$tags" in *master-of-seat*)
                ok "$(basename "$c") ($drv) keeps master-of-seat";;
            *)  bad "$(basename "$c") ($drv) LOST master-of-seat - the desktop will not start";; esac ;;
    esac
done

sec "seat rules freshness"
STOCK=/usr/lib/udev/rules.d/71-seat.rules
OVER=/etc/udev/rules.d/71-seat.rules
if [ ! -f "$OVER" ]; then
    bad "$OVER missing - the Touch Bar card will join seat0"
elif [ "$STOCK" -nt "$OVER" ]; then
    bad "systemd's $STOCK is NEWER than the override - regenerate: sudo touchbar-t1-gen-seat-rules"
else
    ok "seat rules override is newer than stock systemd's"
fi
[ -f /etc/pacman.d/hooks/95-touchbar-t1-seat-rules.hook ] \
    && ok "pacman hook installed (auto-regenerates after systemd upgrades)" \
    || warn "pacman hook not installed - regenerate seat rules manually after systemd upgrades"

sec "userspace"
if [ -x /usr/local/bin/tiny-dfr ]; then
    grep -q 'iBridge Touchpad' /usr/local/bin/tiny-dfr 2>/dev/null \
        && ok "tiny-dfr carries the T1 digitizer name patch" \
        || bad "tiny-dfr is NOT patched - it will ignore the T1 digitizer"
else
    bad "/usr/local/bin/tiny-dfr missing"
fi
grep -q '^MediaLayerDefault *= *true' /etc/tiny-dfr/config.toml 2>/dev/null \
    && ok "media layer is the default (F-keys on fn)" \
    || warn "MediaLayerDefault not true - the bar shows F1-F12 by default"

sec "services"
for u in touchbar-t1 tiny-dfr; do
    E=$(systemctl is-enabled $u.service 2>&1); A=$(systemctl is-active $u.service 2>&1)
    [ "$E" = enabled ] && [ "$A" = active ] && ok "$u.service $E/$A" || warn "$u.service $E/$A"
done
A=$(systemctl is-enabled apple-ibridge.service 2>&1)
[ "$A" = enabled ] && bad "apple-ibridge.service is enabled - it forces USB config 1 and kills the panel" \
                   || ok "apple-ibridge.service not enabled"
journalctl -b --no-pager 2>/dev/null | grep -qi 'ordering cycle' \
    && bad "systemd reported an ordering cycle this boot" \
    || ok "no ordering cycle this boot"

echo
echo "  $PASS ok, $WARN warnings, $FAIL failures"
[ "$FAIL" = 0 ] || exit 1
