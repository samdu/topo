"""scripts/janitor.py: the decisions over scripted readings, and whole passes
against a fake gh, git, tmux and curl with buddy-prime's bridge played by a
loopback HTTP server. No network beyond loopback, no repository, no session.

    scripts/tests/janitor-test.sh
"""
import http.server
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("SCRIPT", os.path.join(HERE, "..", "janitor.py"))
spec = importlib.util.spec_from_file_location("janitor", SCRIPT)
janitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(janitor)

NOW = datetime(2026, 9, 26, 20, 0, tzinfo=timezone.utc)
HEAD = "abc1234def5678"
LONG_MAIN = "def5678" + "0" * 33


def ago(td):
    return (NOW - td).strftime("%Y-%m-%dT%H:%M:%SZ")


def pr(**kw):
    d = {"number": 7, "title": "x", "isDraft": False, "headRefName": "buddy/x", "headRefOid": HEAD,
         "updatedAt": ago(timedelta(hours=1)), "body": "- [x] suite", "baseRefName": "main", "labels": []}
    d.update(kw)
    return d


def run(conclusion="success", status="completed", since=timedelta(minutes=30)):
    return {"id": 99, "status": status, "conclusion": conclusion, "created_at": ago(since + timedelta(minutes=20)),
            "updated_at": ago(since)}


def job(name, conclusion, failed_step=None, i=1):
    steps = [{"name": "Set up job", "conclusion": "success"}]
    if failed_step:
        steps.append({"name": failed_step, "conclusion": "failure"})
    return {"id": i, "name": name, "conclusion": conclusion, "steps": steps}


def jobs(**concl):
    """jobs(test="failure", topo_unit=("failure", "xcodebuild test (Topo, unit and userland)"))"""
    out = []
    for i, (n, c) in enumerate(concl.items(), 1):
        if isinstance(c, tuple):
            out.append(job(n, c[0], c[1], i))
        else:
            out.append(job(n, c, None, i))
    return out


def kinds(wants):
    return [w["kind"] + ":" + w["key"].split(":")[1] if w["kind"] == "report" else w["kind"] for w in wants]


TEST_STEP = "xcodebuild test (Topo, unit and userland)"


class Decisions(unittest.TestCase):
    def test_a_green_ready_pr_left_by_automerge_is_merged_at_its_head(self):
        w = janitor.decide_pr(pr(), run(), jobs(test="success"), {}, NOW)
        self.assertEqual(kinds(w), ["merge"])
        self.assertEqual(w[0]["head"], HEAD)

    def test_a_green_pr_inside_the_grace_is_left_for_automerge(self):
        self.assertEqual(janitor.decide_pr(pr(), run(since=timedelta(minutes=3)), [], {}, NOW), [])

    def test_an_unchecked_box_is_reported_and_never_merged(self):
        w = janitor.decide_pr(pr(body="- [x] suite\n- [ ] device: the phone"), run(), [], {}, NOW)
        self.assertEqual(kinds(w), ["report:boxes"])

    def test_a_pr_not_on_main_is_not_merged(self):
        self.assertEqual(janitor.decide_pr(pr(baseRefName="release"), run(), [], {}, NOW), [])

    def test_the_label_rule_holds_and_an_unreadable_rule_merges_nothing(self):
        self.assertEqual(janitor.decide_pr(pr(), run(), [], {}, NOW, require_label=True), [])
        w = janitor.decide_pr(pr(labels=[{"name": "automerge"}]), run(), [], {}, NOW, require_label=True)
        self.assertEqual(kinds(w), ["merge"])
        w = janitor.decide_pr(pr(), run(), [], {}, NOW, require_label=None)
        self.assertEqual(kinds(w), ["report:label"])

    def test_a_draft_is_reported_after_the_grace_and_nothing_else(self):
        self.assertEqual(janitor.decide_pr(pr(isDraft=True, updatedAt=ago(timedelta(minutes=5))), None, [], {}, NOW), [])
        w = janitor.decide_pr(pr(isDraft=True), run(), jobs(test="success"), {}, NOW)
        self.assertEqual(kinds(w), ["report:draft"])

    def test_a_run_in_progress_wants_nothing(self):
        self.assertEqual(janitor.decide_pr(pr(), run(None, status="in_progress"), [], {}, NOW), [])
        self.assertEqual(janitor.decide_pr(pr(), run("failure", status="queued"), [], {}, NOW), [])

    def test_no_verdict_is_rerun_once_per_head_then_reported(self):
        j = jobs(test="success", codex=("failure", "Run Codex"), reviewer_ran="failure", review_gate="success")
        w = janitor.decide_pr(pr(), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["rerun"])
        self.assertEqual(w[0]["run_id"], 99)
        state = {"rerun": {f"7:{HEAD}": {"run": 99}}}
        w = janitor.decide_pr(pr(), run("failure"), j, state, NOW)
        self.assertEqual(kinds(w), ["report:red"])
        self.assertIn("no verdict", w[0]["text"])

    def test_a_suite_job_red_at_a_setup_step_is_rerun_once_then_reported(self):
        j = jobs(test="failure", topo_ui=("failure", "Boot the simulator"), reviewer_ran="failure")
        w = janitor.decide_pr(pr(), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["rerun"])
        w = janitor.decide_pr(pr(), run("failure"), j, {"rerun": {f"7:{HEAD}": {}}}, NOW)
        self.assertEqual(kinds(w), ["report:red"])
        self.assertIn("topo_ui", w[0]["text"])

    def test_a_suite_job_whose_tests_failed_is_never_rerun(self):
        j = jobs(test="failure", topo_unit=("failure", TEST_STEP), reviewer_ran="failure")
        w = janitor.decide_pr(pr(updatedAt=ago(timedelta(minutes=20))), run("failure"), j, {}, NOW)
        self.assertEqual(w, [])
        w = janitor.decide_pr(pr(), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["report:idle"])
        for step in ("xcodebuild build-for-testing (Topo)", "swift test (TopoAuth, TopoCore)",
                     "The janitor merges, reruns, publishes and sweeps as docs/janitor.md says",
                     "Require every test target ran and passed"):
            j = jobs(test="failure", others=("failure", step))
            self.assertEqual(kinds(janitor.decide_pr(pr(), run("failure"), j, {}, NOW)), ["report:idle"], step)

    def test_one_suite_job_red_in_its_tests_holds_the_rerun_even_with_another_red_in_setup(self):
        j = jobs(test="failure", topo_ui=("failure", "Boot the simulator"), topo_unit=("failure", TEST_STEP))
        self.assertEqual(kinds(janitor.decide_pr(pr(), run("failure"), j, {}, NOW)), ["report:idle"])

    def test_a_suite_job_red_with_no_failed_step_is_a_lost_runner_and_rerun(self):
        j = [{"id": 1, "name": "test", "conclusion": "failure", "steps": []},
             {"id": 2, "name": "topo_unit", "conclusion": "failure", "steps": [{"name": "Set up job", "conclusion": "success"}]}]
        self.assertEqual(kinds(janitor.decide_pr(pr(), run("failure"), j, {}, NOW)), ["rerun"])
        self.assertTrue(janitor.infra_red({"name": "topo_unit", "conclusion": "failure"}))
        self.assertTrue(janitor.infra_red(job("topo_ui", "failure", "Run actions/checkout@v4")))
        self.assertFalse(janitor.infra_red(job("topo_ui", "failure", "xcodebuild test (Topo, UI)")))

    def test_a_red_run_is_left_to_settle_before_a_rerun(self):
        j = jobs(test="failure", topo_ui=("failure", "Boot the simulator"))
        self.assertEqual(janitor.decide_pr(pr(), run("failure", since=timedelta(minutes=2)), j, {}, NOW), [])

    def test_a_new_head_is_rerun_again(self):
        j = jobs(test="failure", topo_ui=("failure", "Boot the simulator"))
        w = janitor.decide_pr(pr(headRefOid="fffffff0000"), run("failure"), j, {"rerun": {f"7:{HEAD}": {}}}, NOW)
        self.assertEqual(kinds(w), ["rerun"])

    def test_a_blocking_verdict_is_reported_at_once_never_rerun_and_idle_in_time(self):
        j = jobs(test="success", reviewer_ran="success", review_gate="failure")
        w = janitor.decide_pr(pr(updatedAt=ago(timedelta(minutes=20))), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["report:verdict"])
        w = janitor.decide_pr(pr(), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["report:verdict", "report:idle"])
        self.assertIn("review_gate", w[1]["text"])

    def test_a_cancelled_run_with_nothing_after_it_is_reported(self):
        self.assertEqual(kinds(janitor.decide_pr(pr(), run("cancelled"), [], {}, NOW)), ["report:cancelled"])

    def test_a_ready_pr_with_no_run_is_reported(self):
        self.assertEqual(kinds(janitor.decide_pr(pr(), None, [], {}, NOW)), ["report:norun"])

    def test_report_keys_repeat_only_after_the_repeat_window(self):
        state = {"fired": {"k": (NOW - timedelta(minutes=30)).isoformat()}}
        self.assertFalse(janitor.due(state, "k", NOW))
        state = {"fired": {"k": (NOW - janitor.REPEAT).isoformat()}}
        self.assertTrue(janitor.due(state, "k", NOW))
        self.assertTrue(janitor.due({}, "k", NOW))

    def test_the_install_page_is_republished_only_when_behind_and_not_just_tried(self):
        self.assertIsNone(janitor.decide_publish("abc1234", "abc1234" + "0" * 33, {}, NOW))
        self.assertIsNotNone(janitor.decide_publish("abc1234", LONG_MAIN, {}, NOW))
        self.assertIsNotNone(janitor.decide_publish(None, LONG_MAIN, {}, NOW))
        tried = {"publish": {LONG_MAIN: {"at": (NOW - timedelta(minutes=10)).isoformat(), "ok": False}}}
        self.assertIsNone(janitor.decide_publish("abc1234", LONG_MAIN, tried, NOW))
        old = {"publish": {LONG_MAIN: {"at": (NOW - timedelta(hours=3)).isoformat(), "ok": True}}}
        self.assertIsNotNone(janitor.decide_publish("abc1234", LONG_MAIN, old, NOW))
        self.assertIsNone(janitor.decide_publish("abc1234", None, {}, NOW))

    def test_the_sweep_takes_only_a_tip_that_is_a_merged_head_with_no_open_pr(self):
        wts = janitor.parse_worktrees(
            "worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n"
            "worktree /r/.worktrees/topo-old\nHEAD 2222\nbranch refs/heads/buddy/old\n\n"
            "worktree /r/.worktrees/topo-new\nHEAD 3333\nbranch refs/heads/buddy/new\n\n"
            "worktree /r/.worktrees/topo-reused\nHEAD 4444\nbranch refs/heads/buddy/reused\n\n"
            "worktree /r/.worktrees/topo-ahead\nHEAD 5555\nbranch refs/heads/buddy/ahead\n\n"
            "worktree /r/.worktrees/topo-detached\nHEAD 6666\ndetached\n\n")
        self.assertEqual([w.get("branch") for w in wts], ["main", "buddy/old", "buddy/new", "buddy/reused", "buddy/ahead", None])
        old = ago(timedelta(hours=30))
        history = {
            "main": [{"number": 1, "state": "MERGED", "mergedAt": ago(timedelta(days=9)), "headRefOid": "1111"}],
            "buddy/old": [{"number": 5, "state": "MERGED", "mergedAt": old, "headRefOid": "2222"}],
            "buddy/new": [{"number": 6, "state": "MERGED", "mergedAt": ago(timedelta(hours=2)), "headRefOid": "3333"}],
            # The name was reused: an old merged PR at another head, and a live one now.
            "buddy/reused": [{"number": 2, "state": "MERGED", "mergedAt": old, "headRefOid": "0000"},
                             {"number": 9, "state": "OPEN", "mergedAt": None, "headRefOid": "4444"}],
            # Merged long ago, but the tip has commits past the merged head.
            "buddy/ahead": [{"number": 3, "state": "MERGED", "mergedAt": old, "headRefOid": "5550"}],
        }
        out = janitor.decide_sweep(wts, "/r/topo", lambda b: history.get(b), NOW)
        self.assertEqual([(o["path"], o["number"]) for o in out], [("/r/.worktrees/topo-old", 5)])
        # A reused name whose old PR was merged at this very tip, with a live PR on it now.
        history["buddy/reused"][0]["headRefOid"] = "4444"
        out = janitor.decide_sweep(wts, "/r/topo", lambda b: history.get(b), NOW)
        self.assertEqual([o["path"] for o in out], ["/r/.worktrees/topo-old"])

    def test_failing_tests_are_read_off_an_xcodebuild_log(self):
        log = ("Test Case '-[TopoTests.DraftRowTests testARowComesBack]' failed (1.2 seconds).\n"
               "Test Case '-[TopoTests.DraftRowTests testARowComesBack]' failed (1.3 seconds).\n"
               "/x/Ear.swift:12: error: the ear is not resident\n")
        self.assertEqual(janitor.failing_tests(log),
                         ["TopoTests.DraftRowTests.testARowComesBack", "the ear is not resident"])
        self.assertEqual(janitor.failing_tests(""), [])

    def test_unchecked_boxes_match_automerges_test(self):
        self.assertEqual(janitor.unchecked_boxes("- [x] a\n  * [ ] b\n- [ ] c"), 2)
        self.assertEqual(janitor.unchecked_boxes(None), 0)

    def test_the_peer_token_is_read_off_the_bridges_env_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "env")
            with open(p, "w") as f:
                f.write("export BRIDGE_TOKENS='{}'\nexport BRIDGE_PEER_TOKEN=\"secret-1\"\n")
            self.assertEqual(janitor.peer_token(p), "secret-1")
            self.assertIsNone(janitor.peer_token(os.path.join(d, "absent")))


FAKE = r'''#!/usr/bin/env python3
import json, os, sys
tool = os.path.basename(sys.argv[0]); a = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f: f.write(tool + " " + " ".join(a) + "\n")
S = json.load(open(os.environ["FAKE_SCRIPT"]))
def out(x): print(json.dumps(x) if not isinstance(x, str) else x); sys.exit(0)
if tool == "gh":
    if a[:2] == ["pr", "list"] and "--state" in a and a[a.index("--state") + 1] == "open":
        if S.get("prs_garbage"): out("<html>rate limited</html>")
        out(S["prs"])
    if a[:2] == ["pr", "list"] and "--head" in a: out(S["history"].get(a[a.index("--head") + 1], []))
    if a[:2] == ["variable", "get"]: out("false")
    if a[0] == "api" and "/runs?head_sha=" in a[1]:
        head = a[1].split("head_sha=")[1].split("&")[0]; out(S["runs"].get(head, []))
    if a[0] == "api" and "/jobs?" in a[1]: out(S["jobs"])
    if a[0] == "api" and a[1].endswith("/logs"): out(S.get("log", ""))
    if a[0] == "api" and a[1].endswith("/commits/main"): out(S["main"])
    if a[:2] == ["pr", "merge"] or a[:2] == ["run", "rerun"]: sys.exit(0)
elif tool == "git":
    if "worktree" in a and "list" in a: out(S["worktrees"])
    if "status" in a: out(S.get("status", {}).get(a[a.index("-C") + 1], ""))
    sys.exit(0)
elif tool == "tmux":
    if a[0] == "list-panes": out(S["panes"])
    sys.exit(0)
elif tool == "curl": out(json.dumps({"commit": S["published"]}))
elif tool == "bash": print("fake publish: " + " ".join(a)); sys.exit(S.get("publish_exit", 0))
print("unscripted: " + tool + " " + " ".join(a), file=sys.stderr); sys.exit(1)
'''


class Bridge(http.server.BaseHTTPRequestHandler):
    """buddy-prime's bridge, as far as /deliver goes: records every body and
    bearer, answers what the test scripted."""
    status = 200
    received = []

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        Bridge.received.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        self.send_response(Bridge.status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "delivered" if Bridge.status == 200 else "no"}).encode())

    def log_message(self, *a):
        pass


class WholePass(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Bridge)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/mesh/buddy-prime/deliver"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        Bridge.status, Bridge.received = 200, []
        self.work = tempfile.mkdtemp(prefix="janitor-test")
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", self.work]))
        self.bin = os.path.join(self.work, "bin")
        os.makedirs(self.bin)
        for tool in ("gh", "git", "tmux", "curl", "bash"):
            p = os.path.join(self.bin, tool)
            with open(p, "w") as f:
                f.write(FAKE)
            os.chmod(p, stat.S_IRWXU)
        self.log = os.path.join(self.work, "calls.log")
        self.script = os.path.join(self.work, "script.json")
        self.state = os.path.join(self.work, "state.json")
        self.mesh_env = os.path.join(self.work, "mesh-env")
        with open(self.mesh_env, "w") as f:
            f.write("export BRIDGE_PEER_TOKEN=tok-buddybox\n")
        self.wt = os.path.join(self.work, "wt", "topo-old")
        os.makedirs(self.wt)
        self.env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], FAKE_LOG=self.log,
                        FAKE_SCRIPT=self.script, HOME=self.work, TOPO_JANITOR_DELIVER_URL=self.url,
                        TOPO_JANITOR_MESH_ENV=self.mesh_env)

    def run_pass(self, script, extra=()):
        with open(self.script, "w") as f:
            json.dump(script, f)
        p = subprocess.run([sys.executable, SCRIPT, "--state", self.state, "--checkout", "/r/topo", "--verbose", *extra],
                           env=self.env, capture_output=True, text=True, timeout=60)
        calls = ""
        if os.path.exists(self.log):
            with open(self.log) as f:
                calls = f.read()
        return p, calls

    def state_file(self):
        with open(self.state) as f:
            return json.load(f)

    def scripted(self, **kw):
        s = {"prs": [pr()], "runs": {HEAD: [run()]}, "jobs": jobs(test="success", reviewer_ran="success"),
             "main": LONG_MAIN, "published": "def5678",
             "worktrees": "worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n"
                          f"worktree {self.wt}\nHEAD 2222\nbranch refs/heads/buddy/old\n\n",
             "history": {"buddy/old": [{"number": 5, "state": "MERGED", "mergedAt": ago(timedelta(hours=30)), "headRefOid": "2222"}]},
             "panes": f"topo-old\t{self.wt}/sub\ntopo-old\t{self.wt}\nother\t/elsewhere\ntopo-older\t{self.wt}-2"}
        s.update(kw)
        return s

    def test_a_pass_merges_pinned_to_the_head_sweeps_and_delivers_as_the_host_to_buddy_prime(self):
        p, calls = self.run_pass(self.scripted())
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"gh pr merge 7 --repo samdu/topo --squash --delete-branch --match-head-commit {HEAD}", calls)
        self.assertIn(f"git -C {self.wt} status --porcelain", calls)
        self.assertIn("tmux kill-session -t =topo-old", calls)
        self.assertEqual(calls.count("kill-session"), 1)
        self.assertNotIn("=topo-older", calls)
        self.assertNotIn("=other", calls)
        self.assertIn(f"git -C /r/topo worktree remove {self.wt}", calls)
        self.assertLess(calls.index("kill-session"), calls.index("worktree remove"))
        self.assertNotIn("publish-topo", calls)
        self.assertEqual(len(Bridge.received), 1)
        got = Bridge.received[0]
        self.assertEqual(got["auth"], "Bearer tok-buddybox")
        self.assertEqual(got["path"], "/mesh/buddy-prime/deliver")
        self.assertEqual((got["body"]["from"], got["body"]["sender"], got["body"]["to"]), ("buddy-janitor", "topo-janitor", "buddy-prime"))
        self.assertTrue(got["body"]["id"])
        self.assertIn("merged #7", got["body"]["text"])
        self.assertIn("swept worktree topo-old", got["body"]["text"])
        self.assertIn("killed tmux topo-old", got["body"]["text"])
        self.assertEqual(self.state_file()["pending"], [])

    def test_a_worktree_with_uncommitted_changes_is_left_with_its_sessions_and_said_once(self):
        s = self.scripted(status={self.wt: " M file.swift"})
        p, calls = self.run_pass(s)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("kill-session", calls)
        self.assertNotIn("worktree remove", calls)
        self.assertIn("uncommitted changes", Bridge.received[0]["body"]["text"])
        p, calls = self.run_pass(s)
        self.assertEqual(sum("uncommitted changes" in r["body"]["text"] for r in Bridge.received), 1)
        self.assertNotIn("kill-session", calls)

    def test_a_reused_branch_name_with_a_live_pr_is_never_swept(self):
        s = self.scripted(history={"buddy/old": [
            {"number": 5, "state": "MERGED", "mergedAt": ago(timedelta(hours=30)), "headRefOid": "2222"},
            {"number": 12, "state": "OPEN", "mergedAt": None, "headRefOid": "2222"}]})
        p, calls = self.run_pass(s)
        self.assertNotIn("kill-session", calls)
        self.assertNotIn("worktree remove", calls)

    def test_a_tip_past_the_merged_head_is_never_swept(self):
        s = self.scripted(history={"buddy/old": [
            {"number": 5, "state": "MERGED", "mergedAt": ago(timedelta(hours=30)), "headRefOid": "2220"}]})
        p, calls = self.run_pass(s)
        self.assertNotIn("worktree remove", calls)
        self.assertNotIn("branch -D", calls)

    def test_a_dry_run_runs_nothing_and_prints_the_report(self):
        p, calls = self.run_pass(self.scripted(published="abc1234"), extra=["--dry-run"])
        self.assertEqual(p.returncode, 0, p.stderr)
        for verb in ("pr merge", "kill-session", "worktree remove", "publish-topo"):
            self.assertNotIn(verb, calls)
        self.assertIn("[topo-janitor] pass at", p.stdout)
        self.assertIn("merged #7", p.stdout)
        self.assertIn("republished the install page", p.stdout)
        self.assertEqual(Bridge.received, [])
        self.assertFalse(os.path.exists(self.state))

    def test_the_install_page_is_republished_from_origin_main_and_a_failure_is_reported_with_its_tail(self):
        p, calls = self.run_pass(self.scripted(published="abc1234", publish_exit=1))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("publish-topo.sh origin/main", calls)
        text = Bridge.received[0]["body"]["text"]
        self.assertIn("failed", text)
        self.assertIn("fake publish", text)
        self.assertIn(LONG_MAIN, self.state_file()["publish"])
        p, calls = self.run_pass(self.scripted(published="abc1234", publish_exit=1))
        self.assertEqual(calls.count("publish-topo.sh"), 1)

    def test_no_verdict_is_rerun_once_and_the_second_red_names_the_failing_tests(self):
        j = jobs(test="failure", topo_unit=("failure", "Boot the simulator"), reviewer_ran="failure")
        log = "Test Case '-[TopoTests.EarTests testTheEarHears]' failed (0.1 seconds)."
        s = self.scripted(runs={HEAD: [run("failure")]}, jobs=j, log=log)
        p, calls = self.run_pass(s)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("gh run rerun 99 --repo samdu/topo --failed", calls)
        self.assertNotIn("pr merge", calls)
        p, calls = self.run_pass(s)
        self.assertEqual(calls.count("run rerun"), 1)
        text = Bridge.received[-1]["body"]["text"]
        self.assertIn("red again", text)
        self.assertIn("TopoTests.EarTests.testTheEarHears", text)

    def test_a_genuine_test_failure_is_never_rerun(self):
        j = jobs(test="failure", topo_unit=("failure", TEST_STEP), reviewer_ran="failure")
        s = self.scripted(runs={HEAD: [run("failure")]}, jobs=j)
        for _ in range(3):
            p, calls = self.run_pass(s)
        self.assertNotIn("run rerun", calls)

    def test_a_pr_list_that_cannot_be_read_keeps_the_rerun_state_and_the_pass_still_reports(self):
        j = jobs(test="failure", topo_unit=("failure", "Boot the simulator"))
        s = self.scripted(runs={HEAD: [run("failure")]}, jobs=j)
        p, calls = self.run_pass(s)
        self.assertEqual(calls.count("run rerun"), 1)
        self.assertIn(f"7:{HEAD}", self.state_file()["rerun"])
        p, calls = self.run_pass(dict(s, prs_garbage=True))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"7:{HEAD}", self.state_file()["rerun"], "an unread PR list is not an empty one")
        self.assertIn("could not read the open PRs", Bridge.received[-1]["body"]["text"])
        p, calls = self.run_pass(s)
        self.assertEqual(calls.count("run rerun"), 1)

    def test_a_standing_condition_is_said_once_per_window(self):
        s = self.scripted(prs=[pr(body="- [ ] device: phone")])
        self.run_pass(s)
        p, calls = self.run_pass(s)
        self.assertEqual(sum("Proof box" in r["body"]["text"] for r in Bridge.received), 1)
        self.assertNotIn("pr merge", calls)

    def test_a_report_the_bridge_does_not_take_is_kept_and_one_it_refuses_for_good_is_dropped(self):
        Bridge.status = 503
        p, _ = self.run_pass(self.scripted())
        self.assertIn("kept for the next pass", p.stderr)
        pending = self.state_file()["pending"]
        self.assertTrue(any("merged #7" in l for l in pending))
        Bridge.status = 200
        p, _ = self.run_pass(self.scripted(prs=[], worktrees="worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n"))
        self.assertTrue(any("merged #7" in l for l in Bridge.received[-1]["body"]["text"].splitlines()))
        self.assertEqual(self.state_file()["pending"], [])
        Bridge.status = 400
        p, _ = self.run_pass(self.scripted())
        self.assertIn("dropped", p.stderr)
        self.assertEqual(self.state_file()["pending"], [])

    def test_no_peer_token_keeps_the_report(self):
        os.remove(self.mesh_env)
        p, _ = self.run_pass(self.scripted())
        self.assertIn("no BRIDGE_PEER_TOKEN", p.stderr)
        self.assertTrue(self.state_file()["pending"])
        self.assertEqual(Bridge.received, [])


if __name__ == "__main__":
    unittest.main()
