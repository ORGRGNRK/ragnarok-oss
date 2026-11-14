#!/bin/bash
# Turn on Alexus's GTX 1080 for Ollama. Run on Alexus with sudo (the owner). Safe to run twice.
#  1. NVIDIA driver 580 (Ubuntu's recommended one for this card)
#  2. NVIDIA container toolkit (from NVIDIA's own apt repository) so Docker can use the card
# Afterwards: reboot Alexus. Then Claude adds the card to the Ollama container (docker compose, no sudo needed).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
exec > >(tee -a /var/log/ragnarok-gpu-setup.log) 2>&1
echo "== $(date -Is) GPU setup started by ${SUDO_USER:-root}"
apt-get update
apt-get install -y nvidia-driver-580 nvidia-utils-580
install -d -m 755 /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
echo "== $(date -Is) done. Now reboot Alexus:  sudo reboot"
