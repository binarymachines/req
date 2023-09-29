\pset tuples_only
SELECT json_agg(row_to_json(file_assets))
FROM file_assets
