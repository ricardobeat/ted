# Working on ted

ted is a text editor built on milktea (`vendor/milktea`, a symlink to the
milktea checkout). It builds two ways:

- `c3c build ted` — the terminal app, `out/ted`.
- `c3c build ted-gui` — the raylib window, `out/ted-gui`.

Change milktea and ted together when an API moves; both repos are committed
separately. Run milktea's tests with `c3c test` in the milktea checkout.

## Testing the UI

Nothing here needs a person at the screen. Every check below runs from a
shell and leaves a file or a line of output to look at.

### Screenshots of the GUI

`TED_SHOT=<path.png>` renders the GUI in a hidden window, writes the frame
to the PNG once any scheduled test input has fired, and exits:

```sh
TED_SHOT=/tmp/shot.png ./out/ted-gui src/ted.c3
```

The image is at device scale (2x on a Retina Mac): the default 800x540pt
window is 1600x1080px.

Put the app in a state first with these, read at startup:

| Variable | Effect |
|---|---|
| `TED_DIALOG=about\|shortcuts\|quit\|menu` | open that dialog, or the File menu |
| `TED_FOCUS=menu\|files\|browser` | move keyboard focus there |
| `TED_FONT_SIZE=<pt>` | text size |
| a path argument | open that file, as a user would |

### Synthetic input

milktea's GUI loop takes scheduled input from the environment and sends it
through the same dispatch path real input uses (hover, click targets, ids):

| Variable | Effect |
|---|---|
| `MILKTEA_DEBUG_POINTER_AT="col,row,frame"` | move the pointer there on that frame |
| `MILKTEA_DEBUG_CLICK_AT="col,row,frame"` | click there on that frame |
| `MILKTEA_DEBUG_KEY_AT="<key>,frame"` | press a key on that frame |
| `MILKTEA_DEBUG_MOUSE=1` | log every press and what it hit |

Coordinates are whole cells, turned into pixels as `col * cell_w`,
`row * cell_h`. So:

- Row 0 is y = 0, which falls in the menu bar's top padding, above the
  titles and the window buttons; use row 1 for the bar. Something smaller
  than a cell, like the window buttons, may be impossible to land on.
  When that happens, force the state with a temporary env check in the
  code, take the shot, and remove the check before committing.
- Read the cell size off a screenshot (a known run of monospace text gives
  the advance) to work out where a target is.

Combine them with a screenshot to see a hover or a click:

```sh
MILKTEA_DEBUG_POINTER_AT="15,5,5" TED_DIALOG=menu TED_SHOT=/tmp/hover.png ./out/ted-gui src/ted.c3
```

### Looking at the result

Crop and enlarge the part that matters, and compare before and after side
by side, with ffmpeg (`sips` crops around the centre and ignores offsets):

```sh
ffmpeg -loglevel error -y -i a.png -vf "crop=W:H:X:Y,scale=iw*3:-1:flags=neighbor" a_crop.png
ffmpeg -loglevel error -y -i a_crop.png -i b_crop.png -filter_complex vstack both.png
```

When the eye is not to be trusted (a shadow that "looks" light against a
dark background), sample the pixels:

```sh
ffmpeg -loglevel error -y -i a.png -vf "crop=80:1:X:Y" -f rawvideo -pix_fmt rgb24 row.raw
python3 -c "d=open('row.raw','rb').read(); print([tuple(d[i:i+3]) for i in range(0,len(d),18)])"
```

### The terminal build

`./out/ted --render` runs the terminal app against a 100x30 test screen and
prints what it drew, with `TED_DIALOG` / `TED_FOCUS` as above. It shows
layout and text, not colour. `TED_OPEN` together with `--render` currently
crashes (the dump runs two programs and the second reads the first's
temporary memory); to test with a file open, feed input to the first
program instead.

### Timing

For "it feels slow", measure before changing anything:

- Wrap `m.view()` and the paint loop in `milktea_gui.c3` with
  `time::clock::now()` / `.mark()` and print per frame.
- Print each decoration cache miss in `decor_cached` (size and time): new
  menus and dialogs rasterise their shadows on first show.
- Profile a steady state with `sample <pid> 3`, forcing a redraw every frame
  with a temporary `g_dirty = true` at the top of the loop.

Take all timing code back out before committing.
