# ted

A text editor built on [milktea](lib/milktea).

```sh
c3c build ted       # terminal: out/ted
c3c build ted-gui   # macOS window: out/ted-gui
./out/ted-gui src/ted.c3
```

## Keys

| Key | Action |
|---|---|
| Ctrl+P | Search files |
| Ctrl+N, Ctrl+O, Ctrl+S | New, open, save |
| Ctrl+B | Toggle sidebar |
| Ctrl+Q | Quit |
| Ctrl+=, Ctrl+-, Ctrl+0 | Text size |
| Esc | Menu bar / back to editor |
| Tab | Menu bar ↔ sidebar |
| ? | Shortcuts |

## Settings

ted reads JSON settings from `$TED_SETTINGS`, `$XDG_CONFIG_HOME/ted/settings.json`
or `~/.config/ted/settings.json`. For example:

```jsonc
{
  "caret": "bar",               // block, bar, underline
  "font_size": 14,
  "font_family": "Menlo",
  "word_wrap": true,
  "line_numbers": 10,           // true, false, every n-th line
  "indent_guides": "all"        // current, all, none
}
```
