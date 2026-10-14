# Rationalising the suites

What a validation costs on buddybox alone, measured over the ten validations kept under `~/Library/Logs/topo-validate` on 2026-10-13, and what to change about it, ranked by minutes returned per validation against the risk to what the suite proves. The sibling plan `plan-park-slow-tests.md` (on the Desktop, parked for Sam's call) covers the slowest unit tests and is not repeated here.

## Where the minutes go

A validation runs its suites one after another in the one slot: `topo_unit`, then `topo_ui`, then `others`, 43 to 53 minutes in all. Nothing inside a suite runs in parallel.

| Suite | Wall | What it is |
|---|---|---|
| `topo_unit` | 11 min (16 to 20 beside another run) | `TopoTests` 8.3 min for 1,724 tests, 584 s of test time, of which `MarkdownRenderTests` is 246 s (the parked plan); the userland bundles 1.5 min; a warm build-for-testing under a minute; the simulator booted twice for the photos grant |
| `topo_ui` | 19 min, or 29 | 52 tests in 18 min (the 48 quiet ones take the same 18 min on thicc-boi); build, lane and boot about a minute; and in three runs of seven, ten minutes after the last test in which xcodebuild's `simctl diagnose` of the simulator timed out at the 600 s it allows (`Failure collecting diagnostics from simulator`), the whole of the 19-versus-29 variance |
| `others` | 13 to 14 min | the scripts' 21 tests, one after another, about 10 min: `ci-audio-lane` 193 s, `validate-and-push` 176 s, `janitor` 121 s, `simulator-run` 105 s, `mac-suite` 47 s, the other sixteen under 20 s each; the six packages, Womble, the watch's suite and the four builds about 3 min warm |

The UI tests themselves: a test is a launch of the app (8 to 10 s on the simulator) and then waits on elements with bounds of 10 to 60 s, none of which is a sleep. The slowest are the ones that launch more than once: `StatusNoticeTests` launches once per notice fixture inside two of its tests (71 s and 72 s), and `TopoPlacementTests`, `TopoOnTheGlassTests` and `DraftRowTests` launch per test at 20 to 60 s each. `CarryJudgeTests`, ten tests in 0.5 s, launches nothing and sits in the UI target.

Flakes: the kept logs hold one red validation, and it is the iOS 27 runtime move's fifteen (keyboard focus, a table rule's width, the widgets' reference pictures), which `buddy/sim-runtime-27` is fixing. The 200 ms sleep in the mirror's test was #416. No other intermittent failure is in the ten runs kept; the UI tests' waits are all bounded `waitForExistence` calls.

## Ranked

1. **No `simctl diagnose` after the tests.** Every test action runs with `-collect-test-diagnostics never`. Returns 10 min on about two UI runs in five and the odd unit run, 15 s otherwise, and 320 MB a result bundle. Risk: none to the proof; the bundle keeps each test's log and attachments, nothing reads the diagnostics, and a crash report stays in `~/Library/Logs/DiagnosticReports` on the Mac. Checked on Womble's suite on a throwaway simulator: with the flag the bundle has no `simctl_diagnostics`. PR: #418 (`buddy/no-simctl-diagnose`).
2. **The scripts' tests at once.** Each runs against fakes in a scratch directory of its own, so `suite_scripts` can start all 21 and wait, each with its own log as now: the wall is the slowest test, about 3.5 min, not the sum. Returns about 7 min from every `others` and from `scripts`. Risk: a test that reaches shared state (the real cache directory, a fixed port, the user's git configuration) passes alone and fails beside another, which is found on the first run and fixed in that test; the signal path has to end every test still running, not one. PR: #419 (`buddy/scripts-tests-parallel`).
3. **One launch per class where the tests only read.** `TopoPlacementTests`, `TopoOnTheGlassTests` and `DraftRowTests` launch per test to read a placement or a row; a class-level launch in `setUp` with the debug environment's reset between tests would return 3 to 5 min of `topo_ui`. Risk: state left for the next test (a pin, a draft); each test has to put back what it moved through the same debug environment it already uses, and a test that relaunches on purpose (the pin outliving a relaunch) keeps its own launch.
4. **The notices' words to the unit suite.** What each notice says in the bar is a render of the same view `ChatNoticesRenderTests` already draws hosted; `StatusNoticeTests` launching once per fixture (two tests, 143 s) proves the words a second time. Keep one launched test per class for the bar's placement beside the badge and move the words and the absurd-font case to the hosted render. Returns about 2 min of `topo_ui`. Risk: the proof that the notice is in the navigation bar stays in the launched test; only the words' proof moves.
5. **`CarryJudgeTests` to the unit target.** It launches nothing, so it costs the UI suite nothing to run and everything to build for; in `TopoTests` it runs on every path the UI suite is not chosen for. Returns no minutes, removes a test that lives in the wrong suite.
6. **Prepare once a validation.** `prepare()` (XcodeGen twice, the framework's stamp) runs on each of the three `mac-suite.sh` calls; 20 to 40 s each. Returns about a minute. Risk: a call that skips it reads a project the previous call generated, which is the same commit.
7. **One boot for the photos grant.** `topo_unit` boots, shuts down to edit the TCC row, and boots again, about 40 s. Writing the row before the first boot returns most of it. Risk: the grant written to a device that has not booted once may not be read; try it on one run first.

After 1 and 2 a validation on buddybox alone is about 36 min at the median; after 3 and 4 about 30.

## Considered and not done

- **Parallel UI testing on clones** (`-parallel-testing-enabled`, two workers): 48 quiet tests in about 9 min instead of 18. Not on buddybox, whose memory is shared with the voice assistant and holds one suite's simulators; worth one measured run of `topo_ui:quiet` on a lent Mac.
- **Shortening the scripts' tests' own waits** (fakes that sleep 600 s to be killed, bounds of 7 s exercised in real time): a test at a time and each a different wait; 2 returns most of the minutes without touching what each test holds.
