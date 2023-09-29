#!/usr/bin/env python


'''
Usage:
    wscollapse.py --listfile <datafile> --delimiter <delim>
'''

import os
import re
import docopt


def main(args):
    
    delimiter = args['<delim>']

    with open(args['<datafile>'], 'r') as f:
        for line in f:
            output = re.sub(r"\s+", delimiter, line)            
            print(output)


if __name__ == '__main__':
    args = docopt.docopt(__doc__)
    main(args)