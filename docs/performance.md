# Performance

Two changes, measured on the same phone. The USB frame is 1170×2532. A screenshot returned to the agent is scaled so the long edge is at most 1000 px, which is 462×1000 on this phone. Gesture code still uses raw USB pixels, so `home`, `back`, and clicks on the mirror window are unchanged.

## Smaller tool results

After each MCP call the agent had to look at the tool result before it could choose the next action. Every tool except `status` returned a full USB frame: a 1170×2532 JPEG at quality 0.7, about 400 KB, base64-encoded in the response. The text was only the action and the resolution, so the model had to read the picture. Those pictures stayed in the conversation, and each later step reread all of them.

Three changes in `07dfc0b` cut that payload, compared with `19c68ad`.

1. **Scale the JPEG, not the pointer.** `screenshot` and any attached tool image are scaled so the long edge is at most 1000 px, then encoded at JPEG quality 0.5. On the 1170×2532 frame that is 462×1000. `x` and `y` are pixels of that image. The tool scales them back onto the raw frame per axis (`rawX = agentX / agentWidth × rawWidth`, and the same for Y) before the gesture runs.
2. **Skip a repeat image.** Settle detection and the "did the screen change" check both use an 80×140 grayscale thumbnail, not the full frame. A full-frame compare is about 3 million pixels; the thumbnail is 11,200 samples and is cheap to repeat every 80 ms while waiting for motion to stop. Brightness is enough to see scrolling, transitions, and the keyboard. The score is the mean absolute difference of those samples (0–255). Below 2.5 the frame counts as unchanged. `screenshot` and `wait` always attach a JPEG. A mutating tool with `include_screenshot` set attaches one only when the thumbnail differs from the last image actually sent.
3. **Mutating tools omit the image by default.** `tap`, `double_tap`, `long_press`, `drag`, `flick`, `type_text`, `press_key`, `home`, and `back` take `include_screenshot` (default false). They still wait for the screen to settle, then return one line of text. Pass true, or call `screenshot`, when the next coordinate depends on looking.

The same script was timed on `19c68ad` and on `07dfc0b`: screenshot, tap Safari, wait 1 s, screenshot, tap the address bar, wait 0.4 s, select all, type `apple.com`, press Enter, wait 1.2 s, `home`. Both runs opened Safari on apple.com and returned to the Home Screen. The 2.6 s of waits are inside the wall clock and are the same on both sides.

| | `19c68ad` | `07dfc0b` |
| --- | --- | --- |
| Wall clock | 6.8 s | 5.6 s |
| MCP round trips | 4.2 s | 3.0 s |
| Images returned | 8, each 1170×2532 | 2, each 462×1000 |
| JPEG bytes | 2.35 MB | 100 KB |
| Response bytes | 3.14 MB | 138 KB |

The 1.2 s difference is encoding and sending fewer images. One `screenshot` call stayed about 0.11 s either way: on localhost a 400 KB body is tens of milliseconds. Settle time still moves around (select-all was 0.59 s after and 0.29 s before). The long pause an agent spends after the tool returns is the model reading those images. That time is outside the round trip. The payload it has to read went from eight full frames to two small ones.

## Coordinate grid

The next wait was outside MCP. The agent had a 462×1000 JPEG and still started a Python process to draw a labeled grid before it could read a tap point. This change draws that grid in the app, on the downscaled image, before the JPEG is encoded. `screenshot`, `wait`, and the mutating tools take `coordinates` (default false). The default path is the one measured above.

The before tree is a git worktree of `07dfc0b`. Its `screenshot` tool takes no arguments. The after tree is the working copy, and the debug app built from it is the one that was already serving MCP. Both binaries are Debug. The phone was still, so settle returned as soon as two frames agreed. Each figure is the median of 7 calls after one warmup.

On `07dfc0b` the path to a labeled image is the tool call, then a new `python3` process. The script is the one the agent ran: Pillow draws a grid every 40 px and writes a JPEG at quality 70. With `coordinates` set, the app draws a grid every 50 px and encodes at quality 0.5. The labels are tap coordinates, origin top-left.

| | `07dfc0b` | After, grid off | After, grid on |
| --- | --- | --- | --- |
| Plain screenshot | 97 ms | 99 ms | — |
| Time until a labeled JPEG exists | 156 ms | — | 102 ms |
| Grid step inside that time | 55 ms, a new `python3` | — | drawn before encode |
| JPEG | 57 KB, then 90 KB from Python | 57 KB | 98 KB |
| HTTP response | 76 KB | 76 KB | 131 KB |

A labeled image is ready in 102 ms. The previous path took 156 ms, so this step is 54 ms shorter. Ranges across the 7 runs: 147–193 ms before, 99–120 ms with the grid on. Against the plain screenshot on `07dfc0b` (97 ms, 57 KB, range 96–107 ms), asking for the grid adds about 5 ms and 41 KB.

The draw is a small part of the Python process. An empty `python3 -c` was 15 ms; the grid script was 44 ms in a tight loop, so about 30 ms of that is Pillow. Launched once as its own shell command, the same script returned in 127 ms. In the earlier session that command returned in 934 ms. Both of those are the cost of starting a process around a 30 ms draw. Folding the draw into the screenshot removes that process.

The model still has to look at the picture, and settle time is unchanged. In that earlier session the agent also spent 195 ms, 197 ms, and 153 ms on three Python scans that searched the JPEG for the dock, the Safari icon, and the address bar. Those scans were how it invented coordinates. They are separate from the overlay timed here. The grid is what puts the coordinates on the image.

Leaving `coordinates` false keeps the payload from the first section. A plain screenshot is still about 0.1 s and 57 KB.
