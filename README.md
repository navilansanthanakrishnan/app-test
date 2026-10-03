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

**Your own.** Not a public game server, and not something someone else is
also connected to — see [the scope](#not-for-public-game-servers-not-for-inexperienced-users)
before using it. It assumes an experienced user.

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
| click the dot → Direction | both ways, outbound only, or inbound only |
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
netcut pulse 60          # keep a LONG one-way cut alive (see below)
netcut direction delay   # packets arrive late instead of not at all
netcut delayms 3000      # how late
netcut direction out     # half-open: it cannot send, the peer's traffic arrives
netcut direction both    # a full disconnect (the default)
netcut key grave         # fire on backtick instead: cmd9 | q | grave
netcut seconds 18        # auto-reconnect window, 2-120s (menu sets it too)
netcut pin off           # back to following focus
netcut app Slack 3       # cut for 3 seconds, then restore by itself
netcut probe Spotify     # dry run: what it would block, changes nothing
netcut diag Spotify      # measure what a one-way cut really does to it
netcut status            # ...also lists how many exclusions are loaded
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

## One-way mode

`Direction` decides which way the block runs:

- **Both ways** (default) — an ordinary disconnect.
- **Outbound only** — nothing the app sends gets out, but the peer's packets
  still arrive. The connection is *half-open*: the server keeps talking, and
  as far as it can tell you have gone quiet.
- **Inbound only** — the mirror.

Half-open is the state servers get wrong. A client that crashes is easy; a
client that keeps receiving while its own packets vanish is the one that sits
in your session table until something times out, and the timeout is usually
the thing nobody tested. Pointed at your own service, this reproduces it on
demand.

**Expect it to look like a full disconnect on most things, and measure
rather than assume.** `netcut diag <app>` samples the app's real traffic
before and during a one-way cut and tells you which direction actually
stopped:

```
$ netcut diag "Google Chrome" 5
baseline, 5s ... in 30.9 KB/s   out 175.5 KB/s
cutting OUTBOUND only for 5s ... in 0 B/s   out 2.7 KB/s
outbound: stopped, as asked (175.5 KB/s -> 2.7 KB/s)
inbound:  fell to 0% (30.9 KB/s -> 0 B/s)
```

The block did exactly what it was told — and inbound still went to zero,
with no inbound rule loaded. That is the far end going quiet on its own.

Anything that waits on your acknowledgements stops sending when they stop
arriving. TCP is the obvious case (no ACKs, the peer's send window fills, the
stream stalls in a second or two), but so is every reliable-UDP game protocol
— RakNet, ENet, QUIC and friends all have an acknowledgement layer, and their
congestion control closes the moment you go quiet. So a one-way block on
those looks like a two-way one, a second or two late.

A genuine half-open window needs a protocol that streams at you
unconditionally. If yours acknowledges, a hard block is the wrong instrument:
use one-way *loss* or *delay* (macOS ships `dnctl` for this) so the connection
degrades instead of stalling, or suppress the payload at the application layer
and let the heartbeats through.

## Pulse — holding a one-way cut open for longer than a few seconds

A solid outbound block starves the peer of acknowledgements, and after a few
seconds it concludes you are gone and stops sending. That is what caps a
one-way cut at around four useful seconds, whatever window you set.

`netcut pulse 60` opens the block for 60ms each second. Just enough gets
through to keep the peer talking, so the view stays live for a window of any
length. The cost is honest: some of your own traffic escapes in those gaps,
so instead of being perfectly frozen at the far end you move in steps.
Shorter pulse means less leaks and more risk the peer still gives up; 40-80ms
is the range worth trying. `netcut pulse off` returns to a solid block.

## Delay mode — the one that keeps the view alive

A block is binary, and that is why one-way blocking collapses: stop
acknowledging and the peer stops sending, so you lose the view you were
trying to keep. **Delaying is not binary.** Your packets still arrive, just
late, so the link never dies — the peer keeps streaming to you while
everything you send lands stale.

```sh
netcut direction delay
netcut delayms 3000      # how late, 100-30000ms
```

Then the hotkey: you see the world live and in real time, and the far end
sees you where you were three seconds ago. Press again and the delay lifts.

It is a dummynet pipe rather than a firewall rule — `/etc/pf.conf` already
declares `dummynet-anchor "com.apple/*"`, so it loads into the same anchor
as everything else and still edits no system file. Inbound is never touched,
and the pf states are deliberately **not** killed in this mode, because the
flow is the thing being kept alive.

Two things to know before relying on it:

- **Your own round trips take the hit too.** You see the world live, but
  anything of yours that needs a reply — a hit registering, a purchase, a
  door opening — comes back `delayms` later.
- **Stay under the peer's timeout.** 2–3 seconds is a lag spike. Ten is a
  disconnect, and then you are back to the behaviour you were trying to
  avoid.

## lab/netcut-lab — when a firewall is the wrong instrument

A firewall blocks an **address**. That is all it can do, and it means your
acknowledgements die alongside whatever you were trying to stop — so the far
end stops hearing from you, stops sending, and a one-way block collapses into
a two-way one. Measured, in this repo's own diagnostic: outbound 175.5 KB/s →
2.7 KB/s as instructed, inbound 30.9 KB/s → **0 B/s with no inbound rule
loaded at all**.

For a service you run, `lab/netcut-lab` sits between your client and your
server and decides per packet:

```sh
netcut-lab --listen 127.0.0.1:30000 --upstream 10.0.0.5:5000
# point your client at 127.0.0.1:30000, then from another shell:
netcut-lab ctl hold 5          # 5s: hold state updates, keep keepalives alive
netcut-lab ctl hold 5 --all    # ...drop everything outbound instead
netcut-lab ctl drop-in 5       # the mirror
netcut-lab ctl loss 30 10      # 30% outbound loss for 10s
netcut-lab ctl release ; netcut-lab ctl stats
```

`hold` keeps packets at or below `--keepalive-max` (64 bytes by default)
flowing while dropping the rest, because in most realtime protocols the acks
and heartbeats are the small ones. That keeps the session **up** while the
state updates stop arriving — which is the whole thing a firewall cannot do.
Measured against a stand-in server:

```
normal            server got: state= 38 keepalive= 38   client received= 38
during hold       server got: state=  0 keepalive= 38   client received= 38
after release     server got: state= 38 keepalive= 38   client received= 38
```

UDP, protocol-agnostic, no privileges. It is the right tool for testing what
your server does with a client that has gone quiet but has not gone away —
including whether your own anti-cheat notices.

## Exclusions

`exclusions.txt` is installed next to the privileged helper and read before
any rule is written. A target matching an entry is refused outright, on every
path, with no way to override it from the client side:

```
$ netcut app Roblox
error: Roblox is on the exclusion list (matched "roblox")
```

It ships with the commercial multiplayer clients in it. The file is root
owned, so changing it is a deliberate privileged edit followed by a
reinstall — which is the point. Testing your own service is what this is for;
those are not your own service.

## Only on something you own. This one is not advisory.

**Do not point this at a game you do not own.** Not a public server, not
someone else's experience, not a match with other players in it, not "just
to see". If you did not make the thing on the other end, this tool is not
for you and there is no reading of it that makes it fine.

**The one case it is for:** a service or a game you built, in a private or
solo session, with nobody else connected. That is where breaking the
connection on purpose costs nothing to anyone but you — which is the entire
difference between testing and cheating. A private place of your own with
one player in it is testing. The same keystroke in a public match is not,
and the fact that the tool cannot tell them apart is exactly why this is
written down.

Cutting a client mid-session desyncs it from the server. In a shared session
the other players pay for that desync — they see you freeze, teleport, or
trade hits that already landed — and they did not agree to be part of your
test. Anti-cheat also reads a repeating drop from one client as what it
resembles, and the ban lands on the account, not on the tool.

`exclusions.txt` is the enforced half of this: targets on that list are
refused before any firewall rule is written, and it ships with the
commercial multiplayer clients in it. It is installed root-owned, and from
this version the installer **will not overwrite a list you have curated** —
the shipped copy lands as `exclusions.txt.default` and is only promoted if
nothing is installed yet. Removing an entry is a deliberate, privileged act.
Own that decision.

**It also assumes you know what you are doing.** It loads firewall rules as
root, blocks by address rather than by process, and takes down anything else
talking to those addresses for the length of the cut.

### If you are testing an anti-cheat, read this first

A server-side detector sees one thing: the client stopped sending, and then
its position jumped. **It cannot tell a one-way cut from a two-way one** —
the difference between them is only what *your own screen* shows you, and
your detector does not run on your screen.

So the fiddly asymmetric mode is not the one to validate against. Use the
plain both-ways cut: it is instantaneous, it is the best-tested path here,
and it produces exactly the server-side signature you are trying to catch.
If you find yourself needing the client's view to look right, you have
stopped testing the detector and started tuning the exploit.

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
