#!/usr/bin/env python

'''
Usage:
    parse_header --file <hdr_file> --fields=<field>...
    parse_header --fields=<field>...

'''

import os, sys
import json
import docopt
from mercury.utils import read_stdin


def main(args):

    header_data = None

    if args['<file>']:
        with open(args['<hdr_file>'], 'r') as f:
            header_data = f.read()

    else: # read from stdin
        buffer = []
        for line in read_stdin():
            buffer.append(line)

        header_data = '\n'.join(buffer)

    print(header_data)


if __name__ == '__main__':
    args = docopt.docopt(__doc__)
    main(args)