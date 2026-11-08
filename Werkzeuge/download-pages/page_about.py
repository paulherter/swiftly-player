# -*- coding: utf-8 -*-
"""/about/ in the kit design. Head lines, content and page scripts: Werkzeuge/web-vorlagen/;
the shell (bar, nav, footer) comes from Werkzeuge/web_shell.py. Output: Website/ or --out DIR."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import web_build

web_build.cli(pages=[], steps=['about'])
