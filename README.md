# Auto-lock

Automatic screen lock that follows the network you are on. Off at home, on
everywhere else, and one click to override until you move.

![The panel on an untrusted network: locking in 15 minutes, with the switch to
call this network home](preview.png)

## The glyph

| Icon | Meaning |
|------|---------|
| Padlock, dimmed | The screen locks itself after the usual idle timeout. |
| Coffee cup, bright | The screen stays awake until you lock it yourself. |

The two are Nerd Font `nf-md-lock` and `nf-md-coffee` — the same coffee cup
Omarchy's own stay-awake indicator uses, so the bar keeps one vocabulary.

Click to open the panel, right-click to flip the lock straight from the bar.
The tooltip names the current network and says whether the state is the
network's own setting or an override.

## How it decides

Omarchy already owns the switch: a flag file at
`~/.local/state/omarchy/indicators/stay-awake`, watched by the built-in idle
service. Present means the screen never locks on its own. `omarchy toggle idle`
flips it, the built-in coffee-cup indicator flips it, and so does this widget —
they all agree because they all read and write that one file.

This plugin adds the policy on top:

- **Joining a network applies that network's setting.** Networks you marked as
  home stay awake; anything else — including no network at all — locks on the
  usual idle timeout.
- **Anything else is off.** An unknown café, a hotel, a hotspot: the lock is
  armed. The safe state is the one you get by default.
- **A toggle overrides the current network** and lasts until you switch
  networks. "Stay awake for this one meeting" costs one click and expires by
  itself, from this widget or from the built-in indicator.

Home is applied immediately; away only after the same non-home network has been
seen twice in a row. A Wi-Fi blip on the way to the kitchen should not quietly
re-arm the lock, but arriving somewhere new should arm it without waiting.

Wi-Fi identifies the network when there is any; a wired link is used only when
there is no Wi-Fi, so a laptop docked at home is still recognised by the network
it joined.

## Marking a network as home

Open the panel while connected and turn on **Treat this network as home**. The
change applies at once — no need to rejoin.

Marked networks live in `~/.config/omarchy-autolock/config`, one NetworkManager
connection UUID per line:

```
home=00000000-1111-2222-3333-444444444444  # Home
```

The comment is only there so the file reads; the UUID is what matters. Matching
on the connection UUID rather than the SSID means a café called "Home" cannot
inherit your policy.

## Timeouts

How long "locks after N min" actually is comes from `idle.lock` in
`~/.config/omarchy/shell.json`, so this widget always quotes the real number.
This plugin never changes those timeouts; it only decides whether they apply.

## IPC

```bash
omarchy-shell dbarke.autolock status       # JSON: state, network, home list
omarchy-shell dbarke.autolock toggleLock   # flip, overriding this network
omarchy-shell dbarke.autolock stayAwake    # force awake
omarchy-shell dbarke.autolock allowLock    # force the lock back on
omarchy-shell dbarke.autolock toggle       # open/close the panel
```

`toggleLock` is the one worth a keybinding.

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `refreshIntervalSec` | `10` | How often to ask NetworkManager which network is active. Lock-state changes are picked up immediately regardless, through a file watch. |

## Requires

`nmcli` (NetworkManager) and the built-in `omarchy.idle` service, both of which
ship with Omarchy.
