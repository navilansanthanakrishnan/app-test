# App Test

Cut one application's network with **⌘9**. Press it again and that app is back.
Everything else on the machine stays online.

**It reconnects itself after 20 seconds** — a countdown sits in the corner of
the screen while the app is cut, and the moment it reaches zero the app is
back. You never have to remember you left something offline. Set it to
whatever you want, from the menu or with `netcut seconds 18`.

The dot in the menu bar is the state and nothing else: **blue means that app's
network is down right now, grey means it is connected.**

For testing how an app behaves when its connection drops — reconnect logic,
retry backoff, offline states, your own client against your own server.

## Install

```sh
git clone https://github.com/NavilanSanthanakrishnan/app-test.git
cd app-test
./install.sh
```

One command, one password prompt. It builds the menu-bar app into
`/Applications/App Test.app`, installs a small privileged helper, and starts
both. macOS only; needs the Xcode Command Line Tools (`xcode-select --install`)
and nothing else — no Homebrew, no Python, no dependencies.

`./uninstall.sh` removes all of it.

## Use

Press **⌘9**. That's the whole thing.

**Scope it to one app.** Pin an app under Target and the key only fires while
that app is frontmost — ⌘9 behaves normally in every other app, and you can
use a key with no modifier at all. While something is actually cut the key
stays live everywhere, so you can always reconnect from wherever you are.

| | |
|---|---|
| ⌘9 | cut the app you are in; press again to reconnect |
| after 20s | it reconnects on its own |
| click the dot → Key | three choices, and a bare key needs an app pinned |
| click the dot → Reconnect after | 5, 10, 15, 20, 30, 60 seconds, or Custom… |
| the countdown | shows the app and the seconds left; gone when it hits zero |
| the menu-bar dot | blue = down, grey = connected, red = something failed |
| click the dot → Countdown | put it top left, top right or bottom |
| click the dot → Target | pick a specific app instead of the one in front |
| Spotlight → "App Test" | starts it again if you ever quit it |

The countdown window is click-through and joins every Space, so it stays
visible over a full-screen app.

From a terminal, if you prefer:

```sh
netcut toggle            # same as ⌘9
netcut pin Discord       # attach ⌘9 to one app so it stops following focus
netcut key grave         # fire on backtick instead: cmd9 | q | grave
netcut seconds 18        # auto-reconnect window, 2-120s (menu sets it too)
netcut pin off           # back to following focus
netcut app Slack 3       # cut for 3 seconds, then restore by itself
netcut probe Spotify     # dry run: what it would block, changes nothing
netcut status            # is anything cut right now
netcut restore           # clear any block
```

### Why a bare key is safe here

A global hot key normally takes that key away from every app. This one is
registered and unregistered as you switch apps: with an app pinned it only
exists while that app is frontmost, so Q and backtick stay ordinary keys
everywhere else. With nothing pinned there is no app to scope them to, so a
bare key is simply not registered, and the menu says so.

The exception is while an app is cut: the key stays live until it reconnects
(at most your configured window) so a second press always works, wherever you
are.

## Please don't point this at a multiplayer game

**It will let you. There is no check — that is deliberate, and this is what
replaced it.**

Cutting a multiplayer client's network mid-match is a **lag switch**. Your
client keeps simulating while the server stops hearing from you, and the
desync lands on the other players: they see you teleport, freeze, or trade
hits that already happened. It isn't a trick played on the game, it's a trick
played on the people in it.

It's also an account risk. Anti-cheat treats a repeating connection drop from
one client as exactly what it looks like, and the ban lands on the account.

The case this is for is a client you wrote, against a server you run, with
nobody else in the session.

## How it works

macOS has no per-process firewall available to a script — the Application
Firewall only governs inbound, and pf cannot match on PID. So the app is
identified by the sockets it currently holds:

1. `lsof` lists the exact `local:port->remote:port` tuples that app owns. For
   Electron apps the network helper owns all of them, so matching the bundle
   path catches the whole family.
2. Those remote addresses go into a pf table and a `block drop quick` rule
   pair, loaded into the `com.apple/netcut` sub-anchor — **no system file is
   ever edited**, and flushing that anchor is a complete undo.
3. Existing pf states bypass rule evaluation, so the rules alone change
   nothing. `pfctl -k` kills the states, and only then do the open connections
   actually die. This is the step that is easy to miss.
4. Releasing the block flushes the anchor. A dropped (rather than reset)
   connection is still alive in TCP retransmit, so it resumes rather than
   having to be rebuilt — which is why reconnecting is near-instant.

Both halves are built to stay out of the way of the keypress:

- The address guard is **one `awk` pass**, not a shell loop. Per-address it
  forked about ten subshells and measured **505 ms on 35 addresses**; the same
  decision, verified identical on 24 cases including every dangerous one, now
  takes **5 ms**.
- Finding the target's processes is one `ps`, not `pgrep` plus `ps` (82 ms → 33 ms).
- State kills run `pfctl` directly under `xargs -P 24` with no `sh` wrapper.
- ⌘9 writes to the helper's FIFO **directly** rather than spawning the shell
  CLI, which took ~25 ms per press to start bash and do nothing else.

**It blocks addresses, not processes.** Anything else talking to the same
address goes down for the same window. Narrow for a chat app, wide for a
browser: Chrome can hold ~90 sockets to shared CDN addresses and all of them
drop.

**Some apps can't be isolated.** Safari's connections belong to
`com.apple.WebKit.Networking`, shared by every WebKit app, so a Safari target
finds no sockets of its own and the cut refuses rather than cutting wider.

## Safety

- **Address guard.** Loopback, RFC1918, `100.64.0.0/10` (carrier-grade NAT and
  Tailscale), link-local, multicast and anything shorter than a /16 are
  refused, so a cut can't sever your own route or an SSH session.
- **Bounded.** A cut reconnects itself after its window (20s by default,
  2–120s) — both the app counting down and the helper's own watchdog, so it
  comes back even if the menu-bar app is killed mid-cut. The helper clamps
  whatever window it is handed, so the bound belongs to the privileged side
  rather than the caller.
- **Watchdogs.** The helper restores if its own shell dies mid-cut and flushes
  the anchor on every start, so no block survives a crash or a reboot.
- **Root code is root-owned.** The helper lives in `/usr/local/libexec/netcut`
  and takes work only from a FIFO owned by you, mode 0600, accepting five
  fixed verbs. Nothing it receives is ever evaluated as code.

## Licence

MIT.
