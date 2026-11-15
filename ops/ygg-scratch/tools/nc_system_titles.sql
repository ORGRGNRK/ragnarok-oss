-- SCRATCH workaround: NocoDB 2026.10.0 refuses (422 ERR_SYSTEM_FIELD_NON_MODIFIABLE) to retitle system
-- columns of an external source, but the MCP reads records by the titles Id / CreatedAt / UpdatedAt.
-- Sets the live titles directly in the scratch NocoDB metadata DB (nocodb_meta) for the 5 Ygg bases.
-- Restart ygg-scratch-nocodb afterwards so its metadata cache reloads.
update nc_columns_v2 c set title = v.t
from (values ('id','Id'),('created_at','CreatedAt'),('updated_at','UpdatedAt'),('created_by','nc_created_by'),('updated_by','nc_updated_by')) v(cn,t),
     nc_models_v2 m, nc_bases_v2 b
where c.fk_model_id=m.id and m.base_id=b.id and b.title like 'Ygg %' and c.column_name=v.cn and c.title<>v.t;
