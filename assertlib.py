#!/usr/bin/env python

import os, sys


class AssertionContext(object):
    def __init__(self, description: str, service_registry):
        self.description = description
        self.home = os.getcwd()
