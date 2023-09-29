#!/usr/bin/env python


'''
Usage:
    detect_deletions.py --manifest <manifest_file> --dbassets <filename_list>
'''


import os, sys
import json
import docopt
from mercury.mlog import mlog


def main(args):

    files_in_db = []

    with open(args['<filename_list>'], 'r') as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue

            files_in_db.append(line)

    manifest_files = set()
    
    with open(args['<manifest_file>'], 'r') as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue

            record = json.loads(line)
            manifest_files.add(record['local_file'])


    for filename in files_in_db:        
        if filename not in manifest_files:
            mlog(f'file deletion detected: {filename}')
            print(filename)


if __name__ == '__main__':
    args = docopt.docopt(__doc__)
    main(args)