#!/usr/bin/env python

'''
Usage:
    filter_path_list --file <remote_file_list>
    filter_path_list

'''

'''
Filter out any path entries where the last element is not a file.
This is a convenience function, as when we list the remote files, 
we get at least one "directory" type entry with no trailing filename.

'''

import os, sys
import json
import docopt
from mercury.utils import read_stdin



def main(args):

    filenames = []

    if args['--file']:
        with open(args['<remote_file_list>'], 'r') as f:
            for line in f:
                filenames.append(line.strip())

        for line in filenames:
            tokens = line.split('/')
            last_token = tokens[-1]
            if not last_token:
                continue
            print(line)
    else:
        for line in read_stdin():
            tokens = line.split('/')
            last_token = tokens[-1]
            if not last_token:
                continue
            print(line)
        


if __name__ == '__main__':
    args = docopt.docopt(__doc__)
    main(args)