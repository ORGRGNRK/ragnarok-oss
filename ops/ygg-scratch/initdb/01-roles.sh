#!/bin/sh
# First boot only. Roles: ygg_app (owner / read-write, NocoDB data sources connect as it),
# ygg_read (read-only), nocodb (owns NocoDB's own metadata DB). Passwords are hex, from .env.
set -e
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
create role ygg_app login password '${YGG_APP_PASSWORD}';
create role ygg_read login password '${YGG_READ_PASSWORD}';
create role nocodb login password '${NC_META_PASSWORD}';
create database nocodb_meta owner nocodb;
create database ygg_receipts owner ygg_app;
create database ygg_ragnarok_core owner ygg_app;
create database ygg_business owner ygg_app;
create database ygg_personal owner ygg_app;
create database ygg_social owner ygg_app;
revoke connect on database ygg_receipts, ygg_ragnarok_core, ygg_business, ygg_personal, ygg_social, nocodb_meta from public;
grant connect on database ygg_receipts, ygg_ragnarok_core, ygg_business, ygg_personal, ygg_social to ygg_read;
SQL
