#!/usr/bin/env python


from contextlib import ContextDecorator
import datetime
import re
import urllib.parse

from mercury.mlog import mlog, mlog_err



def create_db_object(table_name, db_svc, **kwargs):
    DbObject = getattr(db_svc.Base.classes, table_name)
    return DbObject(**kwargs)


def to_boolean(raw_bool_value):
    if not raw_bool_value:
        return False

    if raw_bool_value.__class__ == bool:
        return raw_bool_value

    bool_string = raw_bool_value.lower()

    if bool_string in ["true", "t", "1"]:
        return True
    elif bool_string in ["false", "f", "0"]:
        return False

    else:
        raise Exception(f'unsupported boolean string "{raw_bool_value}"')


def all_of(*args):
    expression = " and ".join([str(arg) for arg in args])
    return eval(expression)


def one_of(*args):
    expression = " or ".join([str(arg) for arg in args])
    return eval(expression)


def convert_to_timestamp(date_string: str):
    #  "2021-10-01T08:33:00"

    date_tokens = date_string.split("T")
    if len(date_tokens) != 2:
        raise Exception(f"Unsupported date format: {date_string}")

    date_string = f"{date_tokens[0]} {date_tokens[1]}"
    date_time = datetime.strptime(date_string, "%Y-%m-%d %H:%M:%S")
    return datetime.timestamp(date_time)


def sqla_record_to_dict(sqla_record, *fields):
    result = {}
    for f in fields:
        result[f] = getattr(sqla_record, f)

    return result


class retry_on_exception(ContextDecorator):
    def __init__(self, target_exception_count, target_function, retry_hook, **kwargs):
        super().__init__()
        self.target_function = target_function
        self.retry_hook = retry_hook
        self.target_exception_count = target_exception_count
        self.num_retries = 0
        self.exception_class = kwargs.get("exception_class", Exception)
        self.result = None

    def __enter__(self):
        mlog(
            "Entering retry context with target count %s and %s retries."
            % (self.target_exception_count, self.num_retries)
        )
        while True:
            try:
                mlog(">>> calling retry target...")
                self.result = self.target_function()
                break
            except self.exception_class as err:
                if self.num_retries == self.target_exception_count:
                    mlog(
                        "Exiting retry context in FAIL mode with target count %s and %s retries."
                        % (self.target_exception_count, self.num_retries)
                    )
                    raise err
                else:
                    self.retry_hook()
                    self.num_retries += 1

        return self

    def __exit__(self, *exc):
        mlog(
            "Exiting retry context with target count %s and %s retries."
            % (self.target_exception_count, self.num_retries)
        )
        return False


class retry_on_false_condition(ContextDecorator):
    def __init__(self, target_fail_count, target_function, eval_function, retry_hook):
        super().__init__()
        self.target_function = target_function
        self.eval_function = eval_function  # must return a boolean
        self.retry_hook = retry_hook
        self.target_fail_count = target_fail_count
        self.num_retries = 0
        self.result = None

    def __enter__(self):
        mlog(
            f"Entering retry context with target count {self.target_fail_count} and {self.num_retries} retries."
        )
        while True:
            mlog(">>> calling retry target...")
            self.result = self.target_function()
            if self.eval_function(self.result):
                break

            else:
                if self.num_retries == self.target_fail_count:
                    mlog(
                        f"Exiting retry context in FAIL mode with target count {self.target_fail_count} and {self.num_retries} retries."
                    )
                    break
                else:
                    self.retry_hook()
                    self.num_retries += 1

        return self

    def __exit__(self, *exc):
        mlog(
            f"Exiting retry context with target count {self.target_fail_count} and {self.num_retries} retries."
        )
        return False


def make_sqla_insert_statement(table_name, input_record: dict, onconflict_clause=None):
    field_list = [key for key in input_record.keys()]

    values_clause = _make_sqla_values_clause(input_record)

    return f"INSERT INTO {table_name}({', '.join(field_list)}) {values_clause} {onconflict_clause or ''}"


def _make_sqla_values_clause(input_record: dict):
    values = []
    for k in input_record.keys():
        values.append(f":{k}")

    value_string = ", ".join(values)
    return f"VALUES({value_string})"


def filepath_to_s3uri(pathname):
    if "s3/" in pathname:
        # non-greedy .*? in pattern in case there's an 's3/' later
        # in the pathname and count=1 to only replace the first one
        return re.sub(".*?s3/", "s3://", pathname, count=1)
    else:
        return None


def s3uri_to_bucket_and_key(s3uri):
    # path component of parse_result will look like /bucket_name/a/b/c.jpg
    # split this into bucket_name & a/b/c.jpg (leading '/' removed on both)

    parsed_data = urllib.parse.urlparse(s3uri)
    return parsed_data.hostname, parsed_data.path.lstrip("/")


def get_dates_for_mmdds(start_date, mmdds, delta_days_limit=120):
    """Convert mmdd strings to dates, nearest to a start date"""

    result = {}

    mmdds_to_find = set(filter(None, mmdds))
    delta_days = 0

    while delta_days < delta_days_limit:
        mmdd_date_map = {
            datetime.datetime.strftime(delta_date, "%m%d"): delta_date
            for delta_date in (
                start_date - datetime.timedelta(days=delta_days),
                start_date + datetime.timedelta(days=delta_days),
            )
        }

        for match in mmdds_to_find.intersection(mmdd_date_map):
            result[match] = mmdd_date_map[match]
            mmdds_to_find.remove(match)

        if not mmdds_to_find:
            return result

        delta_days += 1

    return result
