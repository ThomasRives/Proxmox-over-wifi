#!/usr/bin/env bash
set -e

dpkg -i packages/*.deb || true
apt-get install -f -y

echo "Dependencies installed."
./install.sh
