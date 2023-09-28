#!/usr/bin/env python

import os
import json
import uuid
import datetime 
from snap import common
from mercury.dataload import DataStore
from mercury.mlog import mlog, mlog_err


class ObjectFactory(object):
    @classmethod
    def create_db_object(cls, table_name, db_svc, **kwargs):
        DbObject = getattr(db_svc.Base.classes, table_name)
        return DbObject(**kwargs)


class ConsoleDatastore(DataStore):

    def __init__(self,service_object_registry, *channels, **kwargs):
        super().__init__(service_object_registry, *channels, **kwargs)


    def write(self, records, **write_params):
        for raw_rec in records:
            print(raw_rec)


class S3Datastore(DataStore):
    def __init__(self,service_object_registry, *channels, **kwargs):
        super().__init__(service_object_registry, *channels, **kwargs)


    def write(self, records, **write_params):

        s3_svc = self.service_object_registry.lookup('s3')
        infra_svc = self.service_object_registry.lookup('infra')

        bucket_name = infra_svc.lookup_infra_asset('s3_bucket_id')

        for raw_rec in records:
            rec = json.loads(raw_rec)
            filename = rec['local_file']

            local_path = os.path.join(os.getcwd(), s3_svc.local_tmp_path, filename)
            s3_svc.upload_object(local_path, bucket_name)

        
class PostgresDatastore(DataStore):
    def __init__(self, service_object_registry, *channels, **kwargs):
        super().__init__(service_object_registry, *channels, **kwargs)

    '''
    CREATE TABLE "file_assets" (
        "id" uuid NOT NULL,
        "s3_uri" varchar(255) NOT NULL,
        "filename" varchar(32) NOT NULL,
        "source_url_base" varchar(64) NOT NULL,
        "source_url_path" varchar(64) NOT NULL,
        "source_metahash" varchar(255) NOT NULL,
        "created_ts" timestamp NOT NULL,
        "updated_ts" timestamp,
        "replaces_asset_id" uuid,
        PRIMARY KEY ("id")
        );
    '''

    def write_asset_record(self, record, db_service, **write_params):
    
        asset_record = {
            'id': str(uuid.uuid4()),
            's3_uri': 'placeholder',
            'filename': record['local_file'],
            'source_url_base': record['base_url'],
            'source_url_path': record['srcfile'],
            'source_metahash': record['metahash'],
            'created_ts': datetime.datetime.now(),
            'updated_ts': None,
            'replaces_asset_id': None # TODO: look up record-to-replace by filename
        }

        with db_service.txn_scope() as session:
            db_asset_record = ObjectFactory.create_db_object('file_assets', db_service, **asset_record)
            session.add(db_asset_record)
        
        return record['metahash']
    

    def write(self, records, **write_params):
        postgres_svc = self.service_object_registry.lookup("postgres")
        record_type = write_params.get("record_type", "asset")
        for raw_rec in records:
            rec = json.loads(raw_rec)
            
            try:
                output_str = self.write_asset_record(rec, postgres_svc)
                print(output_str)

            except Exception as err:
                mlog_err(
                    err, issue=f"Error ingesting {record_type} record.", record=rec
                )

        """
        TODO:
        1. create a lookup service for item attributes:

        Attributes.productsup_meta (key for an attribute type) --
   
        "farfetch_product_id": csv_row["item_group_id"]
            
        """


class FilteringConsoleDatastore(DataStore):
    def __init__(self, service_object_registry, *channels, **kwargs):
        super().__init__(service_object_registry, *channels, **kwargs)

    def write(self, records, **write_params):
        """
        Usually, we use ngst to land records in a database of some kind --
        but it's agnostic as to target, so we are using it here to filter records.

        We have a pair of service objects, each of which loads our campaign IDs into an
        in-memory hash set. Depending on where the incoming record came from
        (Partnerize or Impact) we'll use one or the other service to find out if the current
        record's campaign ID is on the list."""

        impact_lookup_svc = self.service_object_registry.lookup(
            "impact_cmpgn_id_lookup"
        )
        partnerize_lookup_svc = self.service_object_registry.lookup(
            "partnerize_feed_id_lookup"
        )

        record_source = write_params.get("record_src")

        for raw_rec in records:
            rec = json.loads(raw_rec)

            if record_source == "impact":
                campaign_id = rec["CampaignId"]
                if impact_lookup_svc.find(campaign_id):
                    print(raw_rec)

            elif record_source == "partnerize":
                feed_id = rec["feed_id"]
                if partnerize_lookup_svc.find(feed_id):
                    print(raw_rec)

            else:
                raise Exception(
                    f"Unrecognized record_src parameter {record_source}. Please check your ngst command line."
                )
