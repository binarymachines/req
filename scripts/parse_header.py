#!/usr/bin/env python

'''
Usage:
    parse_header --file <hdr_file> --fields=<field>... [--params=<name:value>...]
    parse_header --fields=<field>...

'''



import os, sys
import re
import json
import docopt
from mercury.utils import read_stdin
from mercury.utils import parse_cli_params


HEADER_ENTRY_RX = re.compile(r'^[a-zA-Z0-9\-]+:')


def hdr_to_dict(header):
    
    data = dict()
    for line in header.split('\n'):
        match = HEADER_ENTRY_RX.search(line)
        if not match:            
            continue

        key = line[match.span()[0]: match.span()[1]].rstrip(':')
        key_extent = match.span()[1] + 1        
        value = line[key_extent:]

        data[key] = value

    return data


def main(args):

    header_data = None

    if args.get('--file'):
        with open(args['<hdr_file>'], 'r') as f:
            header_data = f.read()

    else: # read from stdin
        buffer = []
        for line in read_stdin():
            buffer.append(line)

        header_data = '\n'.join(buffer)

    field_list = args['--fields'][0].split(',')
   
    #TODO: validate header first (raise hell if we got a 40x)

    header_dict = hdr_to_dict(header_data)

    output_record = dict()
    for field in field_list:
        output_record[field] = header_dict.get(field)

    if args.get('--params'):
        extra_fields = parse_cli_params(args['--params'])
        output_record.update(extra_fields)

    print(json.dumps(output_record))

if __name__ == '__main__':
    args = docopt.docopt(__doc__)
    main(args)