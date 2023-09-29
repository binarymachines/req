#!/usr/bin/env python

'''
Usage:
    dfscan.py --listfile <datafile> [--stats=<column:stat>...]
    dfscan.py <datafile> [--stats=<column:stat>...]

'''


import os, sys
import json
import docopt
import pandas as pd
from mercury.utils import parse_cli_params


def main(args):

    if args['--listfile']:
        df = pd.read_json(args['<datafile>'], lines=True)

    else:
        df = pd.read_json(args['<datafile>'])
    
    if args['--stats']:

        raw_param_str = args['--stats']         

        
        stat_list = raw_param_str[0].split(',')

        output_data = dict()

        for item in stat_list:
            tokens = item.split(':')
            column = tokens[0]
            stat = tokens[1]

            command = f"df['{column}'].{stat}()"  # df['age'].std()
            
            key = f'{column} {stat}'
            output_data[key] = eval(command)
            
        print(json.dumps(output_data))

    else:
        print(df.to_string())
    


if __name__ == '__main__':
    args = docopt.docopt(__doc__)
    main(args)