#!/bin/sh
# Writes .env with fresh random secrets (chmod 600). Refuses to overwrite. Prints no values.
set -e; cd "$(dirname "$0")/.."
[ -e .env ] && { echo ".env exists; not overwriting"; exit 1; }
umask 077
h() { openssl rand -hex "$1"; }
{
echo "# ygg-scratch secrets. Scratch only. Never paste these anywhere."
echo "YGG_PG_PORT=5547"
echo "YGG_NC_PORT=8091"
echo "POSTGRES_PASSWORD=$(h 24)"
echo "YGG_APP_PASSWORD=$(h 24)"
echo "YGG_READ_PASSWORD=$(h 24)"
echo "NC_META_PASSWORD=$(h 24)"
echo "NC_AUTH_JWT_SECRET=$(h 32)"
echo "NC_ADMIN_EMAIL=scratch-admin@example.com"
echo "NC_ADMIN_PASSWORD=Ys$(h 14)#9"
} > .env
chmod 600 .env; echo "wrote .env (600)"
