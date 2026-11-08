# -*- coding: utf-8 -*-
"""/supporter/, /supporter/thanks/, /supporter/de/, /supporter/de/danke/ in the kit design. Head lines, content and page scripts: Werkzeuge/web-vorlagen/;
the shell (bar, nav, footer) comes from Werkzeuge/web_shell.py. Output: Website/ or --out DIR."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import web_build

web_build.cli(pages=['supporter/index.html', 'supporter/thanks/index.html', 'supporter/de/index.html', 'supporter/de/danke/index.html'], steps=[])
