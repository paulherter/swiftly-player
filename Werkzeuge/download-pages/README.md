# Download pages

Generates the standalone pages under `Website/download/` and `Website/android/`. The website sits on plain web space, so there is **no build step on deploy**: the finished HTML files are in the repo and uploaded as they are.

```bash
cd Werkzeuge/download-pages
python3 page_appstore.py   # /download/app-store/
python3 page_testflight.py # /download/testflight/
python3 page_windows.py    # /download/windows/
python3 page_linux.py      # /download/linux/
python3 page_android.py    # /android/
```

`parts.py` holds everything the five pages share: head with meta tags and JSON-LD, footer, sketches with pointer and tap ring, the list of other platforms. The three CSS files are building blocks, not shipped files: `style-base.css` (colors, type, grid), `sketches.css` (drawings), `behavior.css` (the **one** motion for buttons and cards: `--hebung`, `--dauer`, `--kurve`, plus `prefers-reduced-motion`).

**Change the structure in `parts.py`, not in one of the five pages**, or they drift apart. Read `git diff Website/` after every run: the scripts regenerate the pages completely, so hand edits to the HTML are lost.

## Supporter page

`SUPPORTER` in `parts.py` switches the page `/supporter/` and every way to it:
`"off"`, `"preview"` (local only, the form does not send) or `"live"`. After a
change run `page_supporter.py` first: it builds or removes the page and keeps the
links on the hand-written pages (`index.html`, `support.html`, `impressum.html`,
`privacy.html`, `datenschutz.html`) between `supporter` markers. Then the other
pages and `blog-build.py`. `website-upload.py` refuses to upload while the switch
is not `"live"` and the site still links to the page.

