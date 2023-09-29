#!/usr/bin/env python

from sqlalchemy import select, bindparam, and_
from sqlalchemy.schema import Table


def filter_manifest_records(json_rec, raw_line, service_registry, **kwargs):

    db_svc = service_registry.lookup('postgres')

    with db_svc.connect() as connection:

        FileAsset = Table("file_assets", db_svc.metadata, autoload_with=db_svc.engine)
        
        stmt = select(FileAsset).where(
            and_(FileAsset.c.filename == bindparam('filename'), FileAsset.c.deleted_ts == None)
        )
        result = connection.execute(stmt, [{"filename": json_rec['local_file']}])

        matching_records = 0
        for record in result:
            if record.source_metahash == json_rec['metahash']:
                matching_records += 1


        if matching_records > 1:
            raise Exception('+++++++ FATAL DATABASE INCONSISTENCY: duplicate hashes found')

        # matching record found, do not re-download
        if matching_records == 1:              
            return False
        
        # no matching record, good to go
        return True



    