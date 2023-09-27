#!/usr/bin/env python

import os, sys
import json
from json.decoder import JSONDecodeError
from snap import snap, common

from collections import namedtuple
from contextlib import contextmanager
import datetime
import time
import boto3
import sqlalchemy as sqla
from sqlalchemy.ext.automap import automap_base
from sqlalchemy import Column, ForeignKey, Integer, String
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import relationship
from sqlalchemy.orm.session import sessionmaker
from sqlalchemy import create_engine
from sqlalchemy import MetaData
from sqlalchemy_utils import UUIDType


from mercury.mlog import mlog, mlog_err
import uuid

import psycopg2
import rq_utils as utils


S3_AUTH_ERROR_MESSAGE = """
S3ServiceObject must be passed the "aws_key_id" and "aws_secret_key"
parameters if the "auth_via_iam" init param is not set (or is False).
"""

PSYCOPG_SVC_PARAM_NAMES = [
    "dbname",
    "username",
    "password",
    "host",
    "port",
    "connect_timeout",
]

POSTGRESQL_SVC_PARAM_NAMES = ["host", "port", "dbname", "username", "password"]


class DeduplicatorService(object):
    def __init__(self, **kwargs):
        pass
        """
        PLACEHOLDER: load all item attributes into dictionary (keyed by MDS hashes)
        
        """


class SimpleAWSSecretService(object):
    def __init__(self, **kwargs):
        if not kwargs.get("aws_region"):
            raise Exception(
                '"aws_region" is a required keyword argument for SimpleAWSSecretService.'
            )

        region = kwargs["aws_region"]
        profile = kwargs.get("profile", "default")

        if profile == "default":
            # logger.debug('creating boto3 session with no profile spec...')
            b3session = boto3.session.Session()
        else:
            # logger.debug('creating boto3 session with profile "%s"...' % profile)
            b3session = boto3.session.Session(profile_name=profile)

        self.asm_client = b3session.client("secretsmanager", region_name=region)

    def get_secret(self, secret_name):
        secret_value = self.asm_client.get_secret_value(SecretId=secret_name)
        return json.loads(secret_value["SecretString"])


class PostgreSQLService(object):
    def __init__(self, **kwargs):
        kwreader = common.KeywordArgReader(*POSTGRESQL_SVC_PARAM_NAMES)
        kwreader.read(**kwargs)

        self.db_name = kwargs["dbname"]
        self.host = kwargs["host"]
        self.port = int(kwargs.get("port", 5432))
        self.username = kwargs["username"]
        self.password = kwargs["password"]
        self.schema = kwargs.get("schema", "public")
        self.metadata = None
        self.engine = None
        self.session_factory = None
        self.Base = None
        self.url = None

        url_template = "{db_type}://{user}:{passwd}@{host}:{port}/{database}"
        db_url = url_template.format(
            db_type="postgresql+psycopg2",
            user=self.username,
            passwd=self.password,
            host=self.host,
            port=self.port,
            database=self.db_name,
        )

        retries = 0
        connected = False
        while not connected and retries < 3:
            try:
                self.engine = sqla.create_engine(db_url, echo=False)
                self.metadata = MetaData(schema=self.schema)
                self.Base = automap_base()
                self.Base.prepare(self.engine, reflect=True)
                self.metadata.reflect(bind=self.engine)
                self.session_factory = sessionmaker(
                    bind=self.engine,
                    autoflush=False,
                    autocommit=False,
                    expire_on_commit=False,
                )

                # this is required. See comment in SimpleRedshiftService
                connection = self.engine.connect()
                connection.close()
                connected = True
                mlog("+++ Connected to PostgreSQL DB.")
                self.url = db_url

            except Exception as err:
                print(err, file=sys.stderr)
                print(err.__class__.__name__, file=sys.stderr)
                print(err.__dict__, file=sys.stderr)
                time.sleep(1)
                retries += 1

        if not connected:
            raise Exception(
                "!!! Unable to connect to PostgreSQL db on host %s at port %s."
                % (self.host, self.port)
            )

    @contextmanager
    def txn_scope(self):
        session = self.session_factory()
        try:
            yield session
            session.commit()
        except:
            session.rollback()
            raise
        finally:
            session.close()

    @contextmanager
    def connect(self):
        connection = self.engine.connect()
        try:
            yield connection
        finally:
            connection.close()


class S3Key(object):
    def __init__(self, bucket_name, s3_object_path):
        self.bucket = bucket_name
        self.folder_path = self.extract_folder_path(s3_object_path)
        self.object_name = self.extract_object_name(s3_object_path)
        self.full_name = s3_object_path

    def extract_folder_path(self, s3_key_string):
        if s3_key_string.find("/") == -1:
            return ""
        key_tokens = s3_key_string.split("/")
        return "/".join(key_tokens[0:-1])

    def extract_object_name(self, s3_key_string):
        if s3_key_string.find("/") == -1:
            return s3_key_string
        return s3_key_string.split("/")[-1]

    def __str__(self):
        return self.full_name

    @property
    def uri(self):
        return os.path.join("s3://", self.bucket, self.full_name)


class S3Service(object):
    def __init__(self, **kwargs):
        kwreader = common.KeywordArgReader("local_temp_path", "region")
        kwreader.read(**kwargs)

        self.local_tmp_path = kwreader.get_value("local_temp_path")
        self.region = kwreader.get_value("region")
        self.s3session = None
        self.aws_access_key_id = None
        self.aws_secret_access_key = None
        self.aws_profile_name = None

        auth_method = kwargs.get(
            "auth_method"
        )  # should return one of (basic | profile | iam)

        if auth_method == "iam":
            self.s3client = boto3.client("s3", region_name=self.region)

        elif auth_method == "basic":
            self.aws_access_key_id = kwargs.get("aws_key_id")
            self.aws_secret_access_key = kwargs.get("aws_secret_key")

            if not self.aws_secret_access_key or not self.aws_access_key_id:
                raise Exception(
                    'To initialize the S3ServiceObject with auth method "basic", pass the "aws_key_id" and "aws_secret_key" init params'
                )

            self.s3client = boto3.client(
                "s3",
                region_name=self.region,
                aws_access_key_id=self.aws_access_key_id,
                aws_secret_access_key=self.aws_secret_access_key,
            )
        elif auth_method == "profile":
            self.aws_profile_name = kwargs.get("profile_name")

            if not self.aws_profile_name:
                raise Exception(
                    'To initialize the S3ServiceObject with auth method "profile", pass the "profile_name" init param'
                )

            session = boto3.Session(profile_name=self.aws_profile_name)
            self.s3client = session.client("s3", region_name=self.region)

        else:
            raise Exception(
                "Unsupported or unspecified auth method for S3. Must be one of (basic | profile | iam)"
            )

    def upload_object(self, local_filename, bucket_name, bucket_path=None):
        s3_path = None
        with open(local_filename, "rb") as data:
            base_filename = os.path.basename(local_filename)
            if bucket_path:
                s3_path = os.path.join(bucket_path, base_filename)
            else:
                s3_path = base_filename
            self.s3client.upload_fileobj(data, bucket_name, s3_path)
        return S3Key(bucket_name, s3_path)

    def upload_json(self, data_dict, bucket_name, bucket_path):
        binary_data = bytes(json.dumps(data_dict), "utf-8")
        self.s3client.put_object(Body=binary_data, Bucket=bucket_name, Key=bucket_path)

    def upload_bytes(self, bytes_obj, bucket_name, bucket_path):
        s3_key = bucket_path
        self.s3client.put_object(Body=bytes_obj, Bucket=bucket_name, Key=s3_key)
        return s3_key

    def download_file(self, bucket_name, s3_key_object, local_filename):
        s3_key_string = str(s3_key_object)
        try:
            obj = self.s3client.get_object(Bucket=bucket_name, Key=s3_key_string)
            data = obj["Body"].read().decode("utf-8")
            with open(local_filename, "w") as f:
                f.write(data)
            return local_filename

        except Exception as err:
            mlog(
                f'Error of type {err.__class__.__name__} thrown while retrieving S3 object "{s3_key_string}": {err}'
            )

    def download_json(self, bucket_name, s3_key_string):
        status = {}
        try:
            obj = self.s3client.get_object(Bucket=bucket_name, Key=s3_key_string)
            jsondata = json.loads(obj["Body"].read().decode("utf-8"))
            status["ok"] = True
            status["data"] = jsondata

        except Exception as err:
            status["ok"] = False
            status[
                "error"
            ] = f'Error of type {err.__class__.__name__} thrown while retrieving S3 object "{s3_key_string}": {err}'

        finally:
            return status

    def download_json_nocatch(self, bucket_name, s3_key_string):
        obj = self.s3client.get_object(Bucket=bucket_name, Key=s3_key_string)
        jsondata = json.loads(obj["Body"].read().decode("utf-8"))
        return jsondata




LOOKUP_SVC_PARAM_NAMES = ["table_name", "key_columns"]


class OLAPDimensionSvc(object):
    def __init__(self, **kwargs):
        self.pg_svc = PostgreSQLService(**kwargs)
        self.dimensions_by_value = {}
        self.dimensions_by_label = {}

        for tbl_name in kwargs["dimension_tables"]:
            self.dimensions_by_value[tbl_name] = self.load_dimension_values(
                tbl_name, self.pg_svc
            )

        for tbl_name in kwargs["dimension_tables"]:
            self.dimensions_by_label[tbl_name] = self.load_dimension_labels(
                tbl_name, self.pg_svc
            )

        mlog(
            "+++ OLAP dimensions loaded:",
            tables=[key for key in kwargs["dimension_tables"]],
        )

    def load_dimension_values(self, table_name, db_svc):
        dim_data = {}
        data_object = getattr(db_svc.Base.classes, table_name)

        with db_svc.txn_scope() as session:
            resultset = session.query(data_object).all()

            for record in resultset:
                dim_data[str(record.value)] = (record.id, record.label)

        return dim_data

    def load_dimension_labels(self, table_name, db_svc):
        dim_data = {}
        data_object = getattr(db_svc.Base.classes, table_name)

        with db_svc.txn_scope() as session:
            resultset = session.query(data_object).all()

            for record in resultset:
                dim_data[str(record.label)] = (record.id, record.value)

        return dim_data

    def dim_id_for_value(self, dim_table_name, value):
        rltuple = self.dimensions_by_value[dim_table_name][str(value)]
        return rltuple[0]

    def dim_id_for_label(self, dim_table_name, label):
        rltuple = self.dimensions_by_label[dim_table_name][str(label)]
        return rltuple[0]

    def dim_label_for_value(self, dim_table_name, value):
        rltuple = self.dimensions[dim_table_name][str(value)]
        return rltuple[1]

    def get_dim_ids_for_timestamp(self, source_timestamp) -> dict:
        datestamp = datetime.datetime.fromtimestamp(int(source_timestamp))

        data = {}
        data["second"] = self.dim_id_for_value("dim_time_second", datestamp.minute)
        data["minute"] = self.dim_id_for_value("dim_time_minute", datestamp.minute)
        data["hour"] = self.dim_id_for_value("dim_time_hour", datestamp.hour)
        data["day"] = self.dim_id_for_value("dim_date_day", datestamp.day)
        data["month"] = self.dim_id_for_value("dim_date_month", datestamp.month)
        data["year"] = self.dim_id_for_value("dim_date_year", datestamp.year)

        return data


class PGObjectLookupSvc(object):
    def __init__(self, **kwargs):
        self.pg_svc = PostgreSQLService(**kwargs)

        # TODO: do this for all service objects

        kwreader = common.KeywordArgReader(*LOOKUP_SVC_PARAM_NAMES)
        kwreader.read(**kwargs)  # TODO: possibly rename this to validate()

        self.table_name = kwargs["table_name"]
        key_columns = kwargs["key_columns"]
        self.lookup_tbl = dict()

        with self.pg_svc.txn_scope() as session:
            data_object = getattr(self.pg_svc.Base.classes, self.table_name)
            resultset = session.query(data_object).all()

            for record in resultset:
                key = self.compose_key(record, *key_columns)
                self.lookup_tbl[str(key)] = record

    def compose_key(self, record, *key_columns):
        key_tokens = []
        for kc in key_columns:
            key_tokens.append(str(getattr(record, kc)))

        return "%".join(key_tokens)

    def find(self, *values):
        key = "%".join(values)
        return self.lookup_tbl.get(key)

    def update(self, record: object, *key_columns):
        key = self.compose_key(record, *key_columns)
        self.lookup_tbl[str(key)] = record
