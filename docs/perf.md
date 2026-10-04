# Timing a launch and a turn

Where the time goes is read off marks the app writes itself. `Perf.mark(_:)` (`Packages/TopoCore/Sources/TopoCore/Perf.swift`) logs one `notice` line per named moment under subsystem `zone.hexagon.topo`, category `perf`: `mark t=<epoch ms> <name> [detail]`. A mark carries a name and nothing of the person's: no words, no tokens, a request's method, route and byte count at most. The route is the path with any segment that is not a short word or a version replaced by `*` and no query (`Forwarder.routeForMark`), since the path is the guest's to choose. `turn.reply.shown` is the reply handed to the view, a frame before it is drawn; `resident.spawned` is a launch that succeeded, and one that failed is `resident.launch.failed`.

## The marks

| Path | Marks, in order |
| ---- | ---- |
| Launch | `app.init.begin sinceProcessStart=<ms>`, `app.housekeeping.begin`/`.end`, `app.init.end`, `chat.appear`, `scene.active`, `chat.log.read`, `ear.load.begin`/`.end`, `voice.load.begin`/`.end` |
| Guest start | `guest.boot.begin`, `guest.downloads.present`, `guest.kernel.booted`, `guest.dns.up`, `guest.tmp.zone.done`, `guest.claude.verified`, `guest.tools.ready`, `guest.proxy.up`, `resident.launch.begin fresh\|resume`, `resident.spawned` |
| Turn | `turn.send`, `turn.runner.made`, `turn.begin`, `turn.lease.acquired`, `turn.log.read`, `turn.person.saved`, `turn.bridge.begin`, `turn.bridge.guestReady`, `turn.guest.write`, `turn.guest.firstLine`, `turn.guest.init`, `turn.guest.text`, `turn.guest.toolUse`, `turn.guest.result`, `turn.brain.answered`, `turn.reply.saved` (or `turn.reply.failed <kind>`), `turn.reply.shown` |
| The guest's requests | `proxy.request <METHOD> <path> bytes=<n>`, `proxy.head … <status>`, `proxy.firstByte`, `proxy.done` |

## A run with nobody at the phone

`scripts/perf-run.sh --device <id> [--build | --app <Topo.app>] "question" ["question" …]` installs a build, launches it cold with `TOPO_PERF_SEND` in its environment, and copies the marks off when the run is done. `PerfRun` (`Apps/Topo/PerfRun.swift`) is what reads the variable: it starts `tmp/topo-perf.log` in the app's container empty, has every mark written there as well as to the log, sends the first question as soon as the scene is up and each next `TOPO_PERF_GAP` seconds (5) after the reply to the last, through the harness's own line (`willSend`, `retry`) as the composer does, and marks `perf.run.done answered=<n>/<m>`. A question counts as answered when its reply is in the transcript, which is waited for up to a minute after its turn ends (a turn saved as a limb's is answered by another device); the run ends at the first question that gets none, and sends nothing when the harness already has words waiting. A proxy mark names a request by the path segments in `Forwarder.routeSegments` and writes `*` for any other. `TOPO_PERF_SEND` is a JSON array of strings, which the script makes from its arguments. One launch is one run, however many windows it restores. The script polls the file with `devicectl device copy from` until that mark is in it, and exits 4 when fewer questions were answered than asked. A blank question is refused before anything is installed (exit 2).

So one run times a cold launch, a question asked into a cold app, and as many warm turns as there are further questions. The questions are sent as the person and land in their transcript.

`PerfRun` is in a release build because a release build is what is timed. The variable reaches the process only from a launch by `devicectl` or Xcode, from a Mac the phone trusts; an ordinary launch has none.

The phone has to be unlocked: `devicectl` refuses to launch an app on a locked one, and the script exits 3 saying so.

## Without the script

The same marks are in the phone's unified log: `sudo log collect --device-udid <hardware udid> --last 15m --output run.logarchive`, then `log show run.logarchive --predicate 'subsystem == "zone.hexagon.topo" AND category == "perf"' --style compact`. The collect needs the phone awake and no `idevicesyslog` attached to it.
