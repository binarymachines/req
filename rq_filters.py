#!/usr/bin/env python


def filter_manifest_records(json_rec, raw_line, service_registry, **kwargs):

    db_svc = service_registry.lookup('postgres')
    

    metahash = json_rec['metahash']



    return False