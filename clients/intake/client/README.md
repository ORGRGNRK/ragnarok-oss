# Intake tables

`Items` is the record of each thing sent in: kind, title, text, original filename, type, size, sha256, who sent it, which machine, tags, an optional project, and whether it is archived.

The file bytes are not in Postgres. They live in the directory named by `INTAKE_BLOB_HOST` in this client's `.env` (on Alexus, inside this project's folder on the root disk). The sha256 is the filename. Sending the same bytes again does not store a second copy.

Archived means hidden. The row stays. There is no delete for the AI or the Heimdall tab.
