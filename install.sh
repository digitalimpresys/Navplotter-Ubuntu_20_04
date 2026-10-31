#!/bin/bash
# Installs or updates the NavPlotter node on a PC with Ubuntu (26.04, also 24.04) or on Raspberry Pi OS:
#   curl -sSL https://raw.githubusercontent.com/digitalimpresys/Navplotter-Ubuntu_20_04/main/install.sh | sudo bash
# or, from a copy of the repository:  sudo ./install.sh
# On a PC the camera service is installed only when asked (NAVPLOTTER_CAMERA=1): the webcam of a laptop is not
# the boat's camera.
set -euo pipefail

REPO=https://github.com/digitalimpresys/Navplotter-Ubuntu_20_04.git
BRANCH=${NAVPLOTTER_BRANCH:-main}
DEST=/opt/navplotter
DATA=/var/lib/navplotter

if [ "$(id -u)" != 0 ]; then echo "Run it with sudo"; exit 1; fi
PI=0
grep -qa Raspberry /proc/device-tree/model 2>/dev/null && PI=1

echo "== Packages"
apt-get update -qq
apt-get install -y -qq python3 python3-serial git curl >/dev/null
# Ubuntu: brltty (Braille displays) takes the CP2102 of the Heltec V2 as soon as it is plugged in, and the
# port disappears. Without a Braille display it is not needed.
if dpkg -s brltty >/dev/null 2>&1; then
  echo "   removing brltty: it takes the serial port of the Heltec V2 (CP2102)"
  apt-get remove -y -qq brltty >/dev/null || true
fi

echo "== Program in $DEST"
HERE=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); fi
if [ -n "$HERE" ] && [ -d "$HERE/navplotter" ] && [ "$HERE" != "$DEST" ]; then
  mkdir -p "$DEST"
  cp -r "$HERE/navplotter" "$HERE/web" "$HERE/systemd" "$HERE/tools" "$DEST/"
elif [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch -q origin "$BRANCH" && git -C "$DEST" checkout -q -B "$BRANCH" "origin/$BRANCH"
else
  rm -rf "$DEST"
  git clone -q -b "$BRANCH" "$REPO" "$DEST"
fi

echo "== User navplotter (serial port access)"
id navplotter >/dev/null 2>&1 || useradd --system --home "$DATA" --shell /usr/sbin/nologin navplotter
usermod -aG dialout,plugdev navplotter   # plugdev: some systems give the ESP32-S3 USB port (Heltec V4) to it
mkdir -p "$DATA"
chown -R navplotter:navplotter "$DATA"

echo "== Fixed name for the Heltec modem (V2: CP2102, V4: ESP32-S3 USB): /dev/navplotter-modem"
cat > /etc/udev/rules.d/99-navplotter-modem.rules <<'RULE'
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", SYMLINK+="navplotter-modem", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1"
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="1001", SYMLINK+="navplotter-modem", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1"
RULE
udevadm control --reload-rules && udevadm trigger || true

if [ ! -f "$DATA/settings.json" ]; then
  # On a PC port 80 may already have a web server (Apache, nginx...): then the web app goes on 8080
  if ss -Hltn 'sport = :80' 2>/dev/null | grep -q .; then
    echo "   port 80 is taken by another program: the web app goes on port 8080"
    echo '{"modem": "/dev/navplotter-modem", "http_port": 8080}' > "$DATA/settings.json"
  else
    echo '{"modem": "/dev/navplotter-modem"}' > "$DATA/settings.json"
  fi
  chown navplotter:navplotter "$DATA/settings.json"
fi
PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("http_port", 80))' "$DATA/settings.json" 2>/dev/null || echo 80)
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "== Firewall (ufw): port $PORT open for the web app"
  ufw allow "$PORT/tcp" >/dev/null
fi

echo "== Service"
install -m 644 "$DEST/systemd/navplotter.service" /etc/systemd/system/navplotter.service
systemctl daemon-reload
systemctl enable -q navplotter
systemctl restart navplotter

# The camera: when asked with NAVPLOTTER_CAMERA=1, or on a Raspberry Pi with a USB camera or a Hailo AI HAT
if [ "${NAVPLOTTER_CAMERA:-}" = 1 ] || { [ "$PI" = 1 ] && { ls /dev/v4l/by-id/* >/dev/null 2>&1 || [ -e /dev/hailo0 ]; }; }; then
  echo "== Camera service (python3-opencv; recognition with the Hailo AI HAT if hailo-all is installed)"
  apt-get install -y -qq python3-opencv python3-numpy >/dev/null
  usermod -aG video navplotter
  install -m 644 "$DEST/systemd/navplotter-camera.service" /etc/systemd/system/navplotter-camera.service
  systemctl daemon-reload
  systemctl enable -q navplotter-camera
  systemctl restart navplotter-camera
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ "$PORT" = 80 ] && P="" || P=":$PORT"
echo
echo "NavPlotter is running. Web app: http://${IP:-$(hostname).local}$P/ (on this PC: http://localhost$P/)"
echo "Settings: $DATA/settings.json   Log: journalctl -u navplotter -f"
if [ "$PI" = 0 ]; then
  echo "On a PC: turn off automatic suspend (Settings > Power), or the node stops when the PC sleeps."
  echo "Voice assistant: bash $DEST/tools/voice-install.sh (as the desktop user, without sudo)"
fi
