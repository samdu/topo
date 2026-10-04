# Timing a launch and a turn

Where the time goes is read off marks the app writes itself. `Perf.mark(_:)` (`Packages/TopoCore/Sources/TopoCore/Perf.swift`) logs one `notice` line per named moment under subsystem `zone.hexagon.topo`, category `perf`: `mark t=<epoch ms> <name> [detail]`. A mark carries a name and nothing of the person's: no words, no tokens, a request's method, route and byte count at most. The route is the path with any segment that is not a short word or a version replaced by `*` and no query (`Forwarder.routeForMark`), since the path is the guest's to choose. `turn.reply.shown` is the reply handed to the view, a frame before it is drawn; `resident.spawned` is a launch that succeeded, and one that failed is `resident.launch.failed`.

## The marks

| Path | Marks, in order |
| ---- | ---- |
| Launch | `app.init.begin sinceProcessStart=<ms>`, `app.housekeeping.begin`/`.end`, `app.init.end`, `chat.appear`, `scene.active`, `chat.log.read`, `ear.load.begin`/`.end`, `voice.load.begin`/`.end` |
| Guest start | `guest.boot.begin`, `guest.downloads.present`, `guest.kernel.booted`, `guest.dns.up`, `guest.tmp.zone.done`, `guest.claude.verified`, `guest.tools.ready`, `guest.proxy.up`, `resident.launch.begin fresh\|resume`, `resident.spawned` |
| Turn | `turn.send`, `turn.runner.made`, `turn.begin`, `turn.lease.acquired`, `turn.log.read`, `turn.person.saved`, `turn.bridge.begin`, `turn.bridge.guestReady`, `turn.guest.write`, `turn.guest.firstLine`, `turn.guest.init`, `turn.text.first` (the first words drawn), `turn.guest.text`, `turn.guest.toolUse`, `turn.guest.result`, `turn.brain.answered`, `turn.reply.saved` (or `turn.reply.failed <kind>`), `turn.reply.shown`, and for a spoken turn `speak.begin`, `speak.firstFrame` |
| The guest's requests | `proxy.request <METHOD> <path> bytes=<n>`, `proxy.head … <status>`, `proxy.firstByte`, `proxy.done` |

## A run with nobody at the phone

`scripts/perf-run.sh --device <id> [--build | --app <Topo.app>] "question" ["question" …]` installs a build, launches it cold with `TOPO_PERF_SEND` in its environment, and copies the marks off when the run is done. `PerfRun` (`Apps/Topo/PerfRun.swift`) is what reads the variable: it starts `tmp/topo-perf.log` in the app's container empty, has every mark written there as well as to the log, sends the first question as soon as the scene is up and each next `TOPO_PERF_GAP` seconds (5) after the last turn is over, through the harness's own line (`willSend`, `retry`) as the composer does, and marks `perf.run.done answered=<n>/<m>`: a question counts as answered when its reply is in the transcript. `TOPO_PERF_SEND` is a JSON array of strings, which the script makes from its arguments. One launch is one run, however many windows it restores. The script polls the file with `devicectl device copy from` until that mark is in it, and exits 4 when fewer questions were answered than asked.

In a timed run the proxy also marks what each `/v1/messages` request is made of and what the API counted of it: `proxy.shape` (`system=<bytes>:<digest>` a block each, `tools=<count>:<bytes>:<digest>`, `messages=<count>:<bytes>`, `head=<digest>` of the first message, `marks=` each `cache_control` by place, `s`, `t` or `m` and an index, with its `ttl`), `proxy.usage in=… cacheRead=… cacheWrite=…` from the answer's `message_start`, and `proxy.usage.out <tokens>` at its end. A digest that differs between two requests is a part that changed, which is what stops a cached prefix being read. They are made only while a run is being timed, since they parse the request.

With `--spoken` (`TOPO_PERF_SPOKEN=1`) the questions are sent as spoken turns once the voice is resident, their replies are read aloud from the phone, and the next question waits for the reading to end. The run waits up to two minutes for the voice, since a fresh install compiles its model on the first load (`voice.load.begin` to `voice.load.end`, 35–44 s on an iPhone 15 Pro), and marks `perf.voice.unready` if it sends without it.

So one run times a cold launch, a question asked into a cold app, and as many warm turns as there are further questions. The questions are sent as the person and land in their transcript.

`PerfRun` is in a release build because a release build is what is timed. The variable reaches the process only from a launch by `devicectl` or Xcode, from a Mac the phone trusts; an ordinary launch has none.

The phone has to be unlocked: `devicectl` refuses to launch an app on a locked one, and the script exits 3 saying so.

## Without the script

The same marks are in the phone's unified log: `sudo log collect --device-udid <hardware udid> --last 15m --output run.logarchive`, then `log show run.logarchive --predicate 'subsystem == "zone.hexagon.topo" AND category == "perf"' --style compact`. The collect needs the phone awake and no `idevicesyslog` attached to it.
