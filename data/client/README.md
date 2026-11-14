# client/ -- the only folder you edit per client

- `schema.json`: the client's tables and fields. The database tables, the AI's tools, validation
  and the test all follow this file. Field types: text, long_text, email, url, integer, number,
  money, boolean, date, datetime, select (needs "choices"). Options per field: required, unique,
  default, max_length, description, "writable": false (the AI can read it but never set it).
- `seed.json`: starting rows, keyed by table name. A table is only seeded while it is empty.

After editing: `./kit check` (validates both files), then `./kit up` (adds new tables/fields;
it never drops anything), then `./kit seed` if you want the starting rows.
Removing or renaming a field in schema.json does NOT delete the old column; the data stays in
the database (see "Changing the tables later" in the main README).
