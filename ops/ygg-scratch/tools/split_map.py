"""Per-project NocoDB bases for the split. base title -> (database, tables)."""
BASES = {
 "Ygg Receipts":      ("ygg_receipts",      ["Write Log","Archive"]),
 "Ygg RAGNAROK Core": ("ygg_ragnarok_core", ["Config","RAGNAROK State","Memories","Alexus Identity","Reminders","Transcript","Knowledge Pipeline"]),
 "Ygg Business":      ("ygg_business",      ["Business","Exit Profiles","Phone Grades","Leads"]),
 "Ygg Personal":      ("ygg_personal",      ["Personal - Record of Truth","Projects","Project Steps","Personal - Resale Inventory"]),
 "Ygg Social":        ("ygg_social",        ["Social Posts"]),
}
# New Write Log columns added by the split (not in the live NocoDB metadata).
NEW_COLS = {
 "Write Log": {
  "Target_Base":   ("Target Base","SingleSelect",["receipts","ragnarok_core","business","personal","social","machine"]),
  "Target_Table":  ("Target Table","SingleLineText",None),
  "Target_Row_Id": ("Target Row Id","Number",None),
  "Target_Key":    ("Target Key","SingleLineText",None),
 }
}
# Decision 2026-10-28: Social Posts added to Write Log's receipt choices.
EXTRA_OPTIONS = {("Write Log","Table_Written"): ["Social Posts"]}
# Cross-database links that the split replaces with Write Log text keys (not rebuilt as Links).
DROPPED_LINK_FKS = {"Business_id","Reminders_id","Knowledge Pipeline_id","Personal - Record of Truth_id",
                    "Personal - Resale Inventory_id","Projects_id","Project Steps_id","Social Posts_id"}
NOT_MIGRATED = {"Momentum Config"}
