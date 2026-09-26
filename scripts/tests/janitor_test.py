"""scripts/janitor.py: the decisions over scripted readings, and one whole pass
against a fake gh, git, tmux and curl. No network, no repository.

    scripts/tests/janitor-test.sh
"""
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("SCRIPT", os.path.join(HERE, "..", "janitor.py"))
spec = importlib.util.spec_from_file_location("janitor", SCRIPT)
janitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(janitor)

NOW = datetime(2026, 9, 26, 20, 0, tzinfo=timezone.utc)
HEAD = "abc1234def5678"


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


def jobs(**concl):
    return [{"id": i, "name": n, "conclusion": c} for i, (n, c) in enumerate(concl.items(), 1)]


def kinds(wants):
    return [w["kind"] + ":" + w["key"].split(":")[1] if w["kind"] == "report" else w["kind"] for w in wants]


class Decisions(unittest.TestCase):
    def test_a_green_ready_pr_left_by_automerge_is_merged_at_its_head(self):
        w = janitor.decide_pr(pr(), run(), jobs(test="success"), {}, NOW)
        self.assertEqual(kinds(w), ["merge"])
        self.assertEqual(w[0]["head"], HEAD)

    def test_a_green_pr_inside_the_grace_is_left_for_automerge(self):
        w = janitor.decide_pr(pr(), run(since=timedelta(minutes=3)), [], {}, NOW)
        self.assertEqual(w, [])

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
        j = jobs(test="success", codex="failure", reviewer_ran="failure", review_gate="success")
        w = janitor.decide_pr(pr(), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["rerun"])
        self.assertEqual(w[0]["run_id"], 99)
        state = {"rerun": {f"7:{HEAD}": {"run": 99}}}
        w = janitor.decide_pr(pr(), run("failure"), j, state, NOW)
        self.assertEqual(kinds(w), ["report:red"])
        self.assertIn("no verdict", w[0]["text"])

    def test_a_red_suite_is_rerun_once_then_reported_with_its_jobs(self):
        j = jobs(test="failure", topo_unit="failure", reviewer_ran="failure")
        w = janitor.decide_pr(pr(), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["rerun"])
        w = janitor.decide_pr(pr(), run("failure"), j, {"rerun": {f"7:{HEAD}": {}}}, NOW)
        self.assertEqual(kinds(w), ["report:red"])
        self.assertIn("topo_unit", w[0]["text"])

    def test_a_red_run_is_left_to_settle_before_a_rerun(self):
        j = jobs(test="failure")
        self.assertEqual(janitor.decide_pr(pr(), run("failure", since=timedelta(minutes=2)), j, {}, NOW), [])

    def test_a_new_head_is_rerun_again(self):
        j = jobs(test="failure")
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
        w = janitor.decide_pr(pr(), run("cancelled"), [], {}, NOW)
        self.assertEqual(kinds(w), ["report:cancelled"])

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
        self.assertIsNotNone(janitor.decide_publish("abc1234", "def5678" + "0" * 33, {}, NOW))
        self.assertIsNotNone(janitor.decide_publish(None, "def5678" + "0" * 33, {}, NOW))
        sha = "def5678" + "0" * 33
        tried = {"publish": {sha: {"at": (NOW - timedelta(minutes=10)).isoformat(), "ok": False}}}
        self.assertIsNone(janitor.decide_publish("abc1234", sha, tried, NOW))
        old = {"publish": {sha: {"at": (NOW - timedelta(hours=3)).isoformat(), "ok": True}}}
        self.assertIsNotNone(janitor.decide_publish("abc1234", sha, old, NOW))
        self.assertIsNone(janitor.decide_publish("abc1234", None, {}, NOW))

    def test_worktrees_of_branches_merged_a_day_ago_are_swept_and_the_checkout_never(self):
        wts = janitor.parse_worktrees(
            "worktree /r/topo\nHEAD 1\nbranch refs/heads/main\n\n"
            "worktree /r/.worktrees/topo-old\nHEAD 2\nbranch refs/heads/buddy/old\n\n"
            "worktree /r/.worktrees/topo-new\nHEAD 3\nbranch refs/heads/buddy/new\n\n"
            "worktree /r/.worktrees/topo-detached\nHEAD 4\ndetached\n\n")
        self.assertEqual([w.get("branch") for w in wts], ["main", "buddy/old", "buddy/new", None])
        merged = {"main": {"number": 1, "mergedAt": NOW - timedelta(days=9)},
                  "buddy/old": {"number": 5, "mergedAt": NOW - timedelta(hours=30)},
                  "buddy/new": {"number": 6, "mergedAt": NOW - timedelta(hours=2)}}
        out = janitor.decide_sweep(wts, "/r/topo", lambda b: merged.get(b), NOW)
        self.assertEqual([(o["path"], o["number"]) for o in out], [("/r/.worktrees/topo-old", 5)])

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


FAKE = r'''#!/usr/bin/env python3
import json, os, sys
tool = os.path.basename(sys.argv[0]); a = sys.argv[1:]
rec = os.environ["FAKE_LOG"]
with open(rec, "a") as f: f.write(tool + " " + " ".join(a) + "\n")
S = json.load(open(os.environ["FAKE_SCRIPT"]))
def out(x): print(json.dumps(x) if not isinstance(x, str) else x); sys.exit(0)
if tool == "gh":
    if a[:2] == ["pr", "list"] and "--state" in a and a[a.index("--state") + 1] == "open": out(S["prs"])
    if a[:2] == ["pr", "list"] and "--head" in a: out(S["merged"].get(a[a.index("--head") + 1], []))
    if a[:2] == ["variable", "get"]: out("false")
    if a[0] == "api" and "/runs?head_sha=" in a[1]:
        head = a[1].split("head_sha=")[1].split("&")[0]; out(S["runs"].get(head, []))
    if a[0] == "api" and "/jobs?" in a[1]: out(S["jobs"])
    if a[0] == "api" and a[1].endswith("/logs"): out(S.get("log", ""))
    if a[0] == "api" and a[1].endswith("/commits/main"): out(S["main"])
    if a[:2] == ["pr", "merge"] or a[:2] == ["run", "rerun"]: sys.exit(0)
elif tool == "git":
    if "worktree" in a and "list" in a: out(S["worktrees"])
    sys.exit(0)
elif tool == "tmux":
    if a[0] == "list-sessions": out(S["tmux"])
    sys.exit(0)
elif tool == "curl": out(json.dumps({"commit": S["published"]}))
elif tool == "bash": print("fake publish: " + " ".join(a)); sys.exit(S.get("publish_exit", 0))
print("unscripted: " + tool + " " + " ".join(a), file=sys.stderr); sys.exit(1)
'''


class WholePass(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="janitor-test")
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
        self.env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"],
                        FAKE_LOG=self.log, FAKE_SCRIPT=self.script, HOME=self.work)

    def run_pass(self, script, extra=()):
        with open(self.script, "w") as f:
            json.dump(script, f)
        p = subprocess.run([sys.executable, SCRIPT, "--state", self.state, "--checkout", "/r/topo", "--verbose", *extra],
                           env=self.env, capture_output=True, text=True, timeout=60)
        calls = open(self.log).read() if os.path.exists(self.log) else ""
        return p, calls

    def scripted(self, **kw):
        head = HEAD
        long_main = "def5678" + "0" * 33
        s = {"prs": [pr()], "runs": {head: [run()]}, "jobs": jobs(test="success", reviewer_ran="success"),
             "main": long_main, "published": "def5678",
             "worktrees": "worktree /r/topo\nHEAD 1\nbranch refs/heads/main\n\n"
                          "worktree /r/.worktrees/topo-old\nHEAD 2\nbranch refs/heads/buddy/old\n\n",
             "merged": {"buddy/old": [{"number": 5, "mergedAt": ago(timedelta(hours=30))}]},
             "tmux": "topo-old\t/r/.worktrees/topo-old/sub\nother\t/elsewhere"}
        s.update(kw)
        return s

    def test_a_pass_merges_pinned_to_the_head_sweeps_and_keeps_an_undelivered_report(self):
        p, calls = self.run_pass(self.scripted())
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"gh pr merge 7 --repo samdu/topo --squash --delete-branch --match-head-commit {HEAD}", calls)
        self.assertIn("tmux kill-session -t topo-old", calls)
        self.assertIn("git -C /r/topo worktree remove /r/.worktrees/topo-old", calls)
        self.assertNotIn("kill-session -t other", calls)
        self.assertNotIn("bash", calls.split("\n")[0])  # the page is at main: no publish
        self.assertNotIn("publish-topo", calls)
        state = json.load(open(self.state))
        self.assertTrue(any("merged #7" in l for l in state["pending"]), state)
        self.assertTrue(any("swept worktree topo-old" in l and "killed tmux topo-old" in l for l in state["pending"]), state)
        self.assertIn("report not delivered", p.stderr)

    def test_a_dry_run_runs_nothing_and_prints_the_report(self):
        p, calls = self.run_pass(self.scripted(published="abc1234"), extra=["--dry-run"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("pr merge", calls)
        self.assertNotIn("kill-session", calls)
        self.assertNotIn("worktree remove", calls)
        self.assertNotIn("publish-topo", calls)
        self.assertIn("[topo-janitor] pass at", p.stdout)
        self.assertIn("merged #7", p.stdout)
        self.assertIn("republished the install page", p.stdout)
        self.assertFalse(os.path.exists(self.state))

    def test_the_install_page_is_republished_from_origin_main_and_a_failure_is_reported_with_its_tail(self):
        p, calls = self.run_pass(self.scripted(published="abc1234", publish_exit=1))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("publish-topo.sh origin/main", calls)
        state = json.load(open(self.state))
        self.assertTrue(any("failed" in l and "fake publish" in l for l in state["pending"]), state)
        self.assertIn("def5678" + "0" * 33, state["publish"])
        # A second pass inside the retry window does not try again.
        p, calls = self.run_pass(self.scripted(published="abc1234", publish_exit=1))
        self.assertEqual(calls.count("publish-topo.sh"), 1)

    def test_no_verdict_is_rerun_once_and_the_second_red_names_the_failing_tests(self):
        j = jobs(test="failure", topo_unit="failure", reviewer_ran="failure")
        log = "Test Case '-[TopoTests.EarTests testTheEarHears]' failed (0.1 seconds)."
        p, calls = self.run_pass(self.scripted(runs={HEAD: [run("failure")]}, jobs=j, log=log))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("gh run rerun 99 --repo samdu/topo --failed", calls)
        self.assertNotIn("pr merge", calls)
        p, calls = self.run_pass(self.scripted(runs={HEAD: [run("failure")]}, jobs=j, log=log))
        self.assertEqual(calls.count("run rerun"), 1)
        state = json.load(open(self.state))
        self.assertTrue(any("red again" in l and "TopoTests.EarTests.testTheEarHears" in l for l in state["pending"]), state)

    def test_a_standing_condition_is_said_once_per_window(self):
        s = self.scripted(prs=[pr(body="- [ ] device: phone")])
        p, calls = self.run_pass(s)
        p, calls = self.run_pass(s)
        state = json.load(open(self.state))
        self.assertEqual(sum("Proof box" in l for l in state["pending"]), 1, state)
        self.assertNotIn("pr merge", calls)


if __name__ == "__main__":
    unittest.main()
