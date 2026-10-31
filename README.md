# screen-split

A tiny Windows daemon for dual-monitor gamers: keep the game on the big screen and everything else on the small one, without fighting you.

When a new top-level window appears, `screen-split` decides once, within its first few seconds, which monitor it belongs on:

- **Game family** (WeGame launcher, Riot Client, League client, or any executable under `-GameRoots`) goes to the **big screen** (default 2560x1440).
- **Everything else** goes to the **small screen** (default 1920x1080), centered and kept maximized if it was maximized.

After that the window is yours. Drag it anywhere and it stays there. The in-match window (`League of Legends.exe`) is never touched, because moving it breaks mouse input.

## Why

Many full-screen games behave only on the primary display. If you also work on a second monitor, every new browser, chat, or terminal window opens on the game screen and steals focus mid-match. Changing the primary display doesn't help because the game breaks. `screen-split` keeps the primary display as it is and routes new windows instead.

## Usage

```powershell
# try it first: log decisions without moving anything
powershell -NoProfile -ExecutionPolicy Bypass -File .\screen-split.ps1 -DryRun

# run for real
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\screen-split.ps1
```

Parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `-GameRoots` | `C:\Program Files (x86)\WeGame\`, `C:\Riot Games\` | Install folders whose executables count as "game" windows |
| `-BigWidth` / `-BigHeight` | 2560 / 1440 | Resolution that identifies the game monitor |
| `-SmallWidth` / `-SmallHeight` | 1920 / 1080 | Resolution that identifies the work monitor |
| `-LogFile` | `%LOCALAPPDATA%\screen-split\screen-split.log` | Decision log (auto-truncated at 300 KB) |
| `-DryRun` | off | Log only, never move windows |

To start it at logon, register a scheduled task with trigger "At log on" and the "run for real" command above.

## How it works

- Polls `EnumWindows` every 300 ms (negligible CPU) and skips owned dialogs, tool windows, cloaked UWP shells, and shell classes.
- Enumerates monitors live with `EnumDisplayMonitors` on every pass. `System.Windows.Forms.Screen.AllScreens` is cached per process, and a windowless daemon never receives `WM_DISPLAYCHANGE`, so the cached list goes stale after the display layout changes.
- Moves with `SetWindowPos(NOZORDER|NOACTIVATE)`, so it never steals focus from the game.

## Support / 打赏

If this project saved you time, you can buy the author a coffee in crypto. Thank you!
如果这个项目帮到了你，欢迎用加密货币打赏支持，谢谢！

| Network | Asset | Address |
|---|---|---|
| TRON (TRC20) | USDT | `TNGdTwE6opH6rmUyoG1JUR7FSyEb4k273R` |

Please send **USDT on the TRON (TRC20) network only** — other tokens or networks sent to this address may be lost.
请只通过 **TRON (TRC20) 网络转 USDT**，其他币种或网络转入可能无法找回。

## License

MIT
