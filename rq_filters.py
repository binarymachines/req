#!/usr/bin/env python

from sqlalchemy import select, bindparam
from sqlalchemy.schema import Table


def filter_manifest_records(json_rec, raw_line, service_registry, **kwargs):

    db_svc = service_registry.lookup('postgres')

    with db_svc.connect() as connection:

        FileAsset = Table("file_assets", db_svc.metadata, autoload_with=db_svc.engine)
        
        stmt = select(FileAsset).where(FileAsset.c.source_metahash == bindparam('metahash'))
        result = connection.execute(stmt, [{"metahash": json_rec['metahash']}])

        existing_records = 0
        for record in result:
            existing_records += 1

        if existing_records > 1:
            raise Exception('+++++++ FATAL DATABASE INCONSISTENCY: duplicate hashes found')

        if existing_records == 1:              
            return False
        
        return True



    