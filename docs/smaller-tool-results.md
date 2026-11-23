# Smaller tool results

After each MCP call the agent had to look at the tool result before it could choose the next action. Every tool except `status` returned a full USB frame: on the test phone that was a 1170×2532 JPEG at quality 0.7, about 400 KB, base64-encoded in the response. The text was only the action and the resolution, so the model had to read the picture. Those pictures stayed in the conversation, and each later step reread all of them.

Three changes cut that payload. Gesture code still uses raw USB pixels, so `home`, `back`, and clicks on the mirror window are unchanged.

1. **Scale the JPEG, not the pointer.** `screenshot` and any attached tool image are scaled so the long edge is at most 1000 px, then encoded at JPEG quality 0.5. On the 1170×2532 frame that is 462×1000. `x` and `y` are pixels of that image. The tool scales them back onto the raw frame per axis (`rawX = agentX / agentWidth × rawWidth`, and the same for Y) before the gesture runs.
2. **Skip a repeat image.** Settle detection and the "did the screen change" check both use an 80×140 grayscale thumbnail, not the full frame. A full-frame compare is about 3 million pixels; the thumbnail is 11,200 samples and is cheap to repeat every 80 ms while waiting for motion to stop. Brightness is enough to see scrolling, transitions, and the keyboard. The score is the mean absolute difference of those samples (0–255). Below 2.5 the frame counts as unchanged. `screenshot` and `wait` always attach a JPEG. A mutating tool with `include_screenshot` set attaches one only when the thumbnail differs from the last image actually sent.
3. **Mutating tools omit the image by default.** `tap`, `double_tap`, `long_press`, `drag`, `flick`, `type_text`, `press_key`, `home`, and `back` take `include_screenshot` (default false). They still wait for the screen to settle, then return one line of text. Pass true, or call `screenshot`, when the next coordinate depends on looking.

The same script was timed on the old build (`19c68ad`) and on this one: screenshot, tap Safari, wait 1 s, screenshot, tap the address bar, wait 0.4 s, select all, type `apple.com`, press Enter, wait 1.2 s, `home`. Both runs opened Safari on apple.com and returned to the Home Screen. The 2.6 s of waits are inside the wall clock and are the same on both sides.

| | Before | After |
| --- | --- | --- |
| Wall clock | 6.8 s | 5.6 s |
| MCP round trips | 4.2 s | 3.0 s |
| Images returned | 8, each 1170×2532 | 2, each 462×1000 |
| JPEG bytes | 2.35 MB | 100 KB |
| Response bytes | 3.14 MB | 138 KB |

The 1.2 s difference is encoding and sending fewer images. One `screenshot` call stayed about 0.11 s either way: on localhost a 400 KB body is tens of milliseconds. Settle time still moves around (select-all was 0.59 s after and 0.29 s before). The long pause an agent used to spend *after* the tool returned is the model reading those images. That time is outside the round trip. The payload it has to read went from eight full frames to two small ones.
