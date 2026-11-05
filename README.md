# Vault

A small native macOS app that shows folders of notes (Markdown, PDF, HTML, images, templates) in a
terminal-style shell. It reads your folders live and never changes them.

    ./build.sh             # builds build/Vault.app
    ./build.sh --install   # also copies it to ~/Applications

## Adding folders

File > Add Folder... (Cmd-O), or edit `~/Library/Application Support/Vault/config.json`:

    { "collections": [ { "name": "BIO 101", "path": "/path/to/folder",
        "web": { "prefix": "Course Site/site/", "base": "https://example.edu/course/" } } ] }

`web` is optional. Links into `prefix` that do not exist on disk open `base` + the rest of the path.

`site` is optional too. When a folder holds an offline copy of a Sphinx / Jupyter Book site, add
`"site": { "root": "Course Site/site", "entry": "intro.html" }` and the app shows that site: the wheel is built from
the site's own sidebar, pages open in the main pane, and links to templates open them in Excel / Word. Anything in the
folder outside the mirror shows under "my notes". `sidebar` in the prompt toggles the site's own menu.
With more than one folder, the top level of the wheel lists them.

## Several folders, like a home directory

The top level (`~`) lists every folder you have added. `File > Add Vault...` (Shift-Cmd-O) takes a whole Obsidian
vault and adds each class folder in it (names like `BIO 101`) as its own entry. A folder named
`attachments` is added hidden, so pasted images resolve by name from any class. Canvases are skipped.

Quick search: Cmd-K opens a palette. Type to jump to any note or page in any folder, with matches inside the text listed below;
start with `>` for commands (themes, reload, edit in Obsidian, reveal in Finder).

Keys: `j` is up and `k` is down; `.` or `l` go in, `,` or `h` go back, `/` opens the prompt, `t` cycles themes.

Math: `$x^2$` and `$$...$$` render with the bundled KaTeX (and `\ce{}` chemistry). The rule is Pandoc's, so
`$A$2` and "$5 and $10" stay literal. Set `"math": false` on a folder to turn it off.

## Layout

    Sources/Vault/main.swift     window, menu, bridge to the page
    Sources/Vault/Library.swift  the folder list, scanning, path confinement
    Sources/Vault/Scheme.swift   serves vault:// to the web view (read-only)
    Resources/shell.html         the interface
    Resources/render.js          Markdown renderer (runs in the app and in Node)
    Tests/render-check.js        node Tests/render-check.js <folder>
    Tests/math-check.js          node Tests/math-check.js <folder>   (every formula through KaTeX)
    Tests/links-check.js         node Tests/links-check.js <vault> <folder>...   (unresolved wikilinks)

Self-test (drives the real UI, writes screenshots, prints results):

    VAULT_SELFTEST=/tmp/vault-shots build/Vault.app/Contents/MacOS/Vault
