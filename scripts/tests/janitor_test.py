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


def run(conclusion="success", status="completed", since=timedelta(minutes=30), number=7):
    return {"id": 99, "status": status, "conclusion": conclusion, "created_at": ago(since + timedelta(minutes=20)),
            "updated_at": ago(since), "pull_requests": [{"number": number}]}


def job(name, conclusion, failed_step=None, i=1, step_conclusion="failure"):
    steps = [{"name": "Set up job", "conclusion": "success"}]
    if failed_step:
        steps.append({"name": failed_step, "conclusion": step_conclusion})
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


def issue(number, title="x", age=timedelta(hours=1), labels=(), comments=0, **kw):
    d = {"number": number, "title": title, "createdAt": ago(age),
         "labels": {"nodes": [{"name": l} for l in labels], "pageInfo": {"hasNextPage": False}}, "comments": {"totalCount": comments}}
    d.update(kw)
    return d


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

    def test_infra_red_is_every_red_step_in_setup_and_only_a_failure(self):
        setup = job("topo_ui", "failure", "Boot the simulator")
        self.assertTrue(janitor.infra_red(setup))
        setup["steps"].append({"name": TEST_STEP, "conclusion": "failure"})
        self.assertFalse(janitor.infra_red(setup), "one red test step among the setup reds is the code's")
        self.assertFalse(janitor.infra_red(job("topo_ui", "cancelled", "Boot the simulator")), "a cancelled job is not a lost runner")
        self.assertFalse(janitor.infra_red(job("topo_ui", "timed_out")))
        self.assertFalse(janitor.infra_red(job("topo_ui", "failure", TEST_STEP, step_conclusion="cancelled")),
                         "a test step cancelled by its timeout-minutes is not green")
        self.assertTrue(janitor.infra_red(job("topo_ui", "failure", "Boot the simulator", step_conclusion="cancelled")),
                        "a setup step cancelled by its timeout-minutes is the runner's, as its failure is")
        self.assertFalse(janitor.infra_red(job("topo_ui", "failure", "Run ./.github/actions/prepare")))
        self.assertTrue(janitor.infra_red(job("topo_ui", "failure", "Run actions/checkout@v4")))

    def test_reds_at_prepare_the_pinned_fetch_and_the_count_are_the_codes(self):
        for step in ("Run ./.github/actions/prepare", "The rootfs, bash and Claude Code for the userland suites",
                     "Every test the lane names ran and passed", "scripts/build-ish.sh"):
            wants = janitor.decide_pr(pr(), run("failure"), jobs(topo_unit=("failure", step)), {}, NOW)
            self.assertNotIn("rerun", kinds(wants), step)

    def test_a_cancelled_suite_job_or_a_red_select_is_not_rerun(self):
        wants = janitor.decide_pr(pr(), run("failure"), jobs(topo_ui="cancelled", reviewer_ran="failure"), {}, NOW)
        self.assertNotIn("rerun", kinds(wants), "a cancelled suite job beside a missing verdict is the run's own")
        wants = janitor.decide_pr(pr(), run("failure"), jobs(select="failure", reviewer_ran="failure", review_gate="failure"), {}, NOW)
        self.assertNotIn("rerun", kinds(wants), "a red select is not the reviewer's doing")
        wants = janitor.decide_pr(pr(), run("failure"), jobs(codex="failure", reviewer_ran="failure", review_gate="failure"), {}, NOW)
        self.assertEqual(kinds(wants), ["rerun"], "the reviewer chain red on its own is no verdict")

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

    def test_the_review_cap_is_reported_as_the_cap_and_never_rerun(self):
        j = jobs(test="success", codex="skipped", reviewer_ran="success", review_gate="failure")
        w = janitor.decide_pr(pr(updatedAt=ago(timedelta(minutes=20))), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["report:cap"])
        self.assertIn("review cap", w[0]["text"])
        j = jobs(topo_ui=("failure", "Boot the simulator"), codex="skipped", reviewer_ran="success", review_gate="failure")
        w = janitor.decide_pr(pr(updatedAt=ago(timedelta(minutes=20))), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["report:cap", "rerun"], "the cap is said and the setup red still rerun")
        # The recount before the post: codex ran, and post_feedback held its verdict.
        j = jobs(test="success", codex="success", reviewer_ran="success", review_gate="failure")
        j.append(job("post_feedback", "success", "Report Codex feedback", 9, step_conclusion="skipped"))
        w = janitor.decide_pr(pr(updatedAt=ago(timedelta(minutes=20))), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["report:cap"])
        j = jobs(test="success", codex="success", post_feedback="success", reviewer_ran="success", review_gate="failure")
        w = janitor.decide_pr(pr(updatedAt=ago(timedelta(minutes=20))), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["report:verdict"], "a posted verdict that blocks is a verdict")

    def test_a_failed_review_count_is_no_verdict_and_rerun(self):
        j = jobs(review_cap="failure", reviewer_ran="failure", review_gate="success")
        w = janitor.decide_pr(pr(), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["rerun"])

    def test_a_blocking_verdict_is_reported_beside_a_suite_red_of_either_kind(self):
        j = jobs(topo_ui=("failure", "Boot the simulator"), reviewer_ran="success", review_gate="failure")
        w = janitor.decide_pr(pr(updatedAt=ago(timedelta(minutes=20))), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["report:verdict", "rerun"], "the verdict is said and the setup red still rerun")
        j = jobs(topo_ui=("failure", TEST_STEP), reviewer_ran="success", review_gate="failure")
        w = janitor.decide_pr(pr(updatedAt=ago(timedelta(minutes=20))), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), ["report:verdict"], "a test red does not hide the verdict")
        j = jobs(topo_ui=("failure", TEST_STEP), reviewer_ran="failure", review_gate="failure")
        w = janitor.decide_pr(pr(updatedAt=ago(timedelta(minutes=20))), run("failure"), j, {}, NOW)
        self.assertEqual(kinds(w), [], "a review_gate red under a reviewer that never ran is no verdict")

    def test_a_red_select_beside_a_setup_red_holds_the_rerun_and_a_red_gate_does_not(self):
        j = jobs(select="failure", topo_ui=("failure", "Boot the simulator"), test="failure")
        self.assertNotIn("rerun", kinds(janitor.decide_pr(pr(), run("failure"), j, {}, NOW)))
        j = jobs(topo_ui=("failure", "Boot the simulator"), test="failure", reviewer_ran="failure", review_gate="failure")
        self.assertEqual(kinds(janitor.decide_pr(pr(), run("failure"), j, {}, NOW)), ["rerun"],
                         "the gate and the reviewer chain are red because the suite is; that is still a runner red")

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

    def test_a_publish_recorded_as_begun_is_not_tried_again_inside_the_retry(self):
        state = {"publish": {LONG_MAIN: {"at": ago(timedelta(minutes=50)), "ok": None}}}
        self.assertIsNone(janitor.decide_publish("abc1234", LONG_MAIN, state, NOW))
        state = {"publish": {LONG_MAIN: {"at": ago(janitor.PUBLISH_RETRY + timedelta(minutes=1)), "ok": None}}}
        self.assertTrue(janitor.decide_publish("abc1234", LONG_MAIN, state, NOW))

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

    def test_an_untriaged_issue_past_the_grace_is_reported_and_a_triaged_one_is_not(self):
        issues = [issue(1, "Old", age=timedelta(hours=3)), issue(2, "Mine", labels=["from-topo", "bug"]),
                  issue(3, labels=["triaged"]), issue(4, comments=1), issue(5, age=timedelta(minutes=5))]
        wants, untriaged, bad = janitor.decide_issues(issues, NOW)
        self.assertEqual(bad, [])
        self.assertEqual([w["key"] for w in wants], ["issue:1", "issue:2"])
        self.assertEqual(wants[0]["text"], "issue: #1 Old, opened 3 h ago, untriaged.")
        self.assertEqual(wants[1]["text"], "issue: #2 Mine (filed by Topo), opened 60 min ago, untriaged.")
        self.assertEqual(untriaged, {1, 2, 5}, "one inside the grace is untriaged, just not said yet")

    def test_a_malformed_issue_node_is_skipped_and_named(self):
        good = issue(1, "Good")
        wants, keep, bad = janitor.decide_issues([good, dict(issue(2), title=None), dict(issue(3), createdAt="nonsense"),
                                                  dict(issue(4), labels=None), dict(issue(5), comments={})], NOW)
        self.assertEqual([w["key"] for w in wants], ["issue:1"])
        self.assertEqual(bad, ["#2", "#3", "#4", "#5"])
        self.assertEqual(keep, {1, 2, 3, 4, 5}, "a malformed node's own key stands")
        wants, keep, bad = janitor.decide_issues([good, dict(issue(8), comments={"totalCount": False}),
                                                  dict(issue(9), labels={"nodes": {}}), dict(issue(10), labels={"nodes": "triaged"})], NOW)
        self.assertEqual(bad, ["#8", "#9", "#10"], "a bool count and labels that are not a list are malformed")
        self.assertEqual([w["key"] for w in wants], ["issue:1"])
        old_shape = dict(issue(11), labels={"nodes": [{"name": f"l{k}"} for k in range(20)]})
        more = dict(issue(12), labels={"nodes": [{"name": "bug"}], "pageInfo": {"hasNextPage": True}})
        wants, keep, bad = janitor.decide_issues([good, old_shape, more], NOW)
        self.assertEqual(bad, ["#11", "#12"], "a label list that may not be whole is malformed")
        self.assertEqual([w["key"] for w in wants], ["issue:1"])
        for node in (None, "x", {"title": "no number"}, dict(issue(6), number="6"), dict(issue(7), number=True)):
            wants, keep, bad = janitor.decide_issues([good, node], NOW)
            self.assertEqual([w["key"] for w in wants], ["issue:1"], node)
            self.assertEqual(bad, ["node 2"], node)
            self.assertIsNone(keep, "with a node that has no number, no issue key may be dropped")

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

    def test_a_command_that_gives_no_answer_in_time_is_a_runtime_error(self):
        with self.assertRaises(RuntimeError) as cm:
            janitor.Shell().run([sys.executable, "-c", "import time; time.sleep(5)"], timeout=0.3)
        self.assertIn("no answer", str(cm.exception))
        with self.assertRaises(RuntimeError):
            janitor.Shell().run(["/nonexistent/tool"])

    def test_more_pending_lines_than_the_cap_drops_the_oldest_and_says_so(self):
        sent = []
        class Sh:
            def post(self, url, body, token):
                sent.append(body["text"]); return 200, "ok"
        with tempfile.TemporaryDirectory() as d:
            env = os.path.join(d, "env")
            with open(env, "w") as f:
                f.write("export BRIDGE_PEER_TOKEN=t\n")
            old = janitor.MESH_ENV
            janitor.MESH_ENV = env
            try:
                state = {"pending": [f"line {i}" for i in range(janitor.PENDING_MAX + 30)]}
                janitor.deliver(Sh(), state, NOW, log=lambda s: None, warn=lambda s: None)
                self.assertEqual(len(sent), 2, "the newest PENDING_MAX lines, then a message saying what was dropped")
                lines = sent[0].splitlines()[1:]
                self.assertEqual(len(lines), janitor.PENDING_MAX)
                self.assertNotIn("line 0\n", sent[0])
                self.assertIn(f"line {janitor.PENDING_MAX + 29}", lines[-1])
                self.assertIn("30 older lines", sent[1])
                self.assertEqual(state["pending"], [])
                self.assertEqual(state["undelivered"], [])
                # Older messages go whole, oldest first, before the newest is cut,
                # and a message already sent is never re-sent with other text.
                state = {"undelivered": [{"id": "a", "at": "t", "lines": ["old"] * 150}, {"id": "b", "at": "t", "lines": ["mid"] * 100}],
                         "pending": ["new"] * 10}
                sent.clear()
                janitor.deliver(Sh(), state, NOW, log=lambda s: None, warn=lambda s: None)
                self.assertEqual([t.count("- old") for t in sent], [0, 0, 0])
                self.assertEqual([t.count("- mid") for t in sent], [100, 0, 0])
                self.assertEqual(sent[0].splitlines()[1:], ["- mid"] * 100, "message b is sent as it was")
                self.assertIn("150 older lines", sent[2])
            finally:
                janitor.MESH_ENV = old

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
    limit = int(a[a.index("--limit") + 1]) if "--limit" in a else 10**9
    if a[:2] == ["pr", "list"] and "--state" in a and a[a.index("--state") + 1] == "open":
        if S.get("prs_garbage"): out("<html>rate limited</html>")
        out(S["prs"][:limit])
    if a[:2] == ["pr", "list"] and "--head" in a:
        branch = a[a.index("--head") + 1]
        asked = open(os.environ["FAKE_LOG"]).read().count("--head " + branch)
        if asked > 1 and branch in S.get("history_later", {}): out(S["history_later"][branch][:limit])
        out(S["history"].get(branch, [])[:limit])
    if a[:2] == ["variable", "get"]: out("false")
    if a[:2] == ["api", "graphql"]:
        if S.get("issues_error"): print(S["issues_error"], file=sys.stderr); sys.exit(1)
        start = int(a[a.index("-f", 3) + 1].split("=", 1)[1]) if a.count("-f") > 1 else 0
        page = S.get("issues", [])[start:start + 100]
        # GitHub answers `labels(first: N)` with at most N labels and says whether more stand.
        import re; first = int(re.search(r"labels\(first: (\d+)\)", a[a.index("-f") + 1]).group(1))
        def cut(i):
            if not (isinstance(i, dict) and isinstance(i.get("labels"), dict) and isinstance(i["labels"].get("nodes"), list)):
                return i
            ls = i["labels"]["nodes"]
            return dict(i, labels={"nodes": ls[:first], "pageInfo": {"hasNextPage": len(ls) > first}})
        page = [cut(i) for i in page]
        more = start + 100 < len(S.get("issues", []))
        out({"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": more, "endCursor": str(start + 100) if more else None},
                                                "nodes": page}}}})
    if a[0] == "api" and "/runs?head_sha=" in a[1]:
        head = a[1].split("head_sha=")[1].split("&")[0]
        out([dict({k: v for k, v in r.items() if k != "pull_requests"}, prs=[p["number"] for p in r.get("pull_requests", [])]) for r in S["runs"].get(head, [])])
    if a[0] == "api" and "/jobs?" in a[1]: out(S["jobs"])
    if a[0] == "api" and a[1].endswith("/logs"): out(S.get("log", ""))
    if a[0] == "api" and a[1].endswith("/commits/main"): out(S["main"])
    if a[:2] == ["pr", "merge"] or a[:2] == ["run", "rerun"]: sys.exit(0)
elif tool == "git":
    if "worktree" in a and "list" in a: out(S["worktrees"])
    if "status" in a: out(S.get("status", {}).get(a[a.index("-C") + 1], ""))
    if "rev-parse" in a: out(S.get("tip", "2222"))
    if "update-ref" in a and S.get("ref_moved"): print("cannot lock ref: is at 3333 but expected 2222", file=sys.stderr); sys.exit(1)
    sys.exit(0)
elif tool == "tmux":
    if a[0] == "list-panes":
        if S.get("tmux_stderr"): print(S["tmux_stderr"], file=sys.stderr); sys.exit(1)
        out(S["panes"])
    sys.exit(0)
elif tool == "curl":
    if S.get("page_down"): print("curl: (22) The requested URL returned error: 502", file=sys.stderr); sys.exit(22)
    out(json.dumps({"commit": S["published"]}))
elif tool == "bash":
    if S.get("publish_snapshot"):
        import shutil; shutil.copy(os.environ["JANITOR_STATE"], S["publish_snapshot"])
    if S.get("publish_hang"):
        import time; time.sleep(float(S["publish_hang"]))
    print("fake publish: " + " ".join(a)); sys.exit(S.get("publish_exit", 0))
print("unscripted: " + tool + " " + " ".join(a), file=sys.stderr); sys.exit(1)
'''


class Bridge(http.server.BaseHTTPRequestHandler):
    """buddy-prime's bridge, as far as /deliver goes: records every body and
    bearer, answers what the test scripted."""
    status = 200
    received = []
    short_body = False   # a 200 with a Content-Length longer than what is sent: IncompleteRead at the client

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        Bridge.received.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        self.send_response(Bridge.status)
        self.send_header("Content-Type", "application/json")
        answer = json.dumps({"status": "delivered" if Bridge.status == 200 else "no"}).encode()
        if Bridge.short_body:
            self.send_header("Content-Length", str(len(answer) + 500))
            self.end_headers()
            self.wfile.write(answer)
            self.wfile.flush()
            self.close_connection = True
            return
        self.end_headers()
        self.wfile.write(answer)

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
        Bridge.status, Bridge.received, Bridge.short_body = 200, [], False
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
                        TOPO_JANITOR_MESH_ENV=self.mesh_env, JANITOR_STATE=self.state)

    def run_pass(self, script, extra=()):
        """One pass; `calls` is what this pass ran, not every pass so far."""
        with open(self.script, "w") as f:
            json.dump(script, f)
        before = self.calls()
        p = subprocess.run([sys.executable, SCRIPT, "--state", self.state, "--checkout", "/r/topo", "--verbose", *extra],
                           env=self.env, capture_output=True, text=True, timeout=60)
        return p, self.calls()[len(before):]

    def state_file(self):
        with open(self.state) as f:
            return json.load(f)

    def undelivered(self):
        return [l for m in self.state_file().get("undelivered", []) for l in m["lines"]]

    def calls(self):
        if not os.path.exists(self.log):
            return ""
        with open(self.log) as f:
            return f.read()

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
        self.assertIn("git -C /r/topo update-ref -d refs/heads/buddy/old 2222", calls)
        self.assertNotIn("branch -D", calls)
        self.assertLess(calls.index("kill-session"), calls.index(f"git -C {self.wt} rev-parse HEAD"))
        self.assertLess(calls.index("rev-parse HEAD"), calls.index("worktree remove"))
        self.assertLess(calls.index("worktree remove"), calls.index("update-ref -d"))
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
        self.assertEqual((self.state_file()["pending"], self.undelivered()), ([], []))

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
        self.assertNotIn("update-ref", calls)

    def test_a_commit_landing_while_the_sweep_looked_leaves_the_worktree_and_the_ref(self):
        p, calls = self.run_pass(self.scripted(tip="3333"))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("kill-session", calls, "the sessions were already killed when the tip was read again")
        self.assertNotIn("worktree remove", calls)
        self.assertNotIn("update-ref", calls)
        self.assertIn("moved to 3333 while the sweep looked; left", Bridge.received[-1]["body"]["text"])
        p, calls = self.run_pass(self.scripted(ref_moved=True))
        self.assertIn("worktree remove", calls)
        self.assertIn("update-ref -d refs/heads/buddy/old 2222", calls)
        self.assertIn("the branch ref moved past 2222 and is kept", Bridge.received[-1]["body"]["text"])

    def test_another_prs_green_run_on_the_same_head_merges_nothing(self):
        s = self.scripted(prs=[pr(), pr(number=8, headRefName="buddy/y")], runs={HEAD: [run(number=8)]})
        p, calls = self.run_pass(s)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("gh pr merge 8", calls)
        self.assertNotIn("gh pr merge 7", calls, "PR 8's run is not PR 7's, whatever the head")
        self.assertIn("#7 (buddy/x): ready with no validate run", Bridge.received[-1]["body"]["text"])

    def test_a_pr_opened_from_the_branch_while_the_sweep_looked_keeps_its_worktree(self):
        later = {"buddy/old": [{"number": 5, "state": "MERGED", "mergedAt": ago(timedelta(hours=30)), "headRefOid": "2222"},
                               {"number": 9, "state": "OPEN", "mergedAt": None, "headRefOid": "2222"}]}
        p, calls = self.run_pass(self.scripted(history_later=later))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(calls.count("--head buddy/old"), 2, "asked once to decide and once before the kills")
        self.assertNotIn("kill-session", calls, "nothing of the PR's is killed")
        self.assertNotIn("worktree remove", calls)
        self.assertNotIn("update-ref", calls)
        self.assertIn("got an open PR while the sweep looked; left", Bridge.received[-1]["body"]["text"])

    def test_a_branch_history_that_fills_its_page_is_not_read_as_whole(self):
        old = {"number": 1, "state": "OPEN", "mergedAt": None, "headRefOid": "0000"}
        newer = [{"number": 2 + i, "state": "MERGED", "mergedAt": ago(timedelta(hours=30)), "headRefOid": "2222"} for i in range(100)]
        p, calls = self.run_pass(self.scripted(history={"buddy/old": newer + [old]}))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("worktree remove", calls)
        self.assertNotIn("kill-session", calls)
        self.assertIn("PR history could not be read", Bridge.received[-1]["body"]["text"])

    def test_an_open_pr_list_that_fills_its_page_is_not_read_as_whole(self):
        many = [pr(number=100 + i, headRefOid=f"{i:040d}") for i in range(200)]
        p, calls = self.run_pass(self.scripted(prs=many))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("pr merge", calls)
        self.assertIn("could not read the open PRs", Bridge.received[-1]["body"]["text"])
        self.assertIn("limit", Bridge.received[-1]["body"]["text"])

    def test_tmux_that_cannot_list_its_panes_stops_the_sweep_and_no_server_is_no_panes(self):
        p, calls = self.run_pass(self.scripted(tmux_stderr="error connecting to /tmp/tmux-501/default (Permission denied)"))
        self.assertNotIn("worktree remove", calls)
        self.assertIn("will not remove", Bridge.received[-1]["body"]["text"])
        self.assertIn("tmux list-panes exited 1", Bridge.received[-1]["body"]["text"])
        p, calls = self.run_pass(self.scripted(tmux_stderr="no server running on /private/tmp/tmux-501/default"))
        self.assertIn("worktree remove", calls)
        self.assertNotIn("kill-session", calls)

    def test_a_pane_in_a_subdirectory_of_the_worktree_is_killed_and_a_sibling_prefix_is_not(self):
        s = self.scripted(panes=f"deep\t{self.wt}/Packages/TopoCore\ntopo-older\t{self.wt}-2/x")
        p, calls = self.run_pass(s)
        self.assertIn("tmux kill-session -t =deep", calls)
        self.assertNotIn("=topo-older", calls)

    def backdate(self, hours=4):
        """Every fired key as if said `hours` ago: the next pass is past REPEAT."""
        state = self.state_file()
        at = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
        state["fired"] = {k: at for k in state["fired"]}
        with open(self.state, "w") as f:
            json.dump(state, f)

    def issue_lines(self, since=None):
        """The issue lines of the last message, or of every message from `since` on."""
        got = Bridge.received[-1:] if since is None else Bridge.received[since:]
        return [l for m in got for l in m["body"]["text"].splitlines() if l.startswith("- issue:")]

    def test_untriaged_issues_are_reported_by_number_and_title_and_never_their_body(self):
        s = self.scripted(issues=[issue(40, "The badge is yellow", body="SECRET-MARKER"),
                                  issue(41, "Topo cannot see the lights", labels=["from-topo"], age=timedelta(hours=5)),
                                  issue(42, "Planned", labels=["triaged"]), issue(43, "Answered", comments=2)])
        p, calls = self.run_pass(s)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(janitor.ISSUES_QUERY, calls)
        self.assertIn("issues(states: OPEN, first: 100, after: $after)", janitor.ISSUES_QUERY, "repository.issues holds no PR")
        self.assertNotIn("body", janitor.ISSUES_QUERY)
        self.assertNotIn("gh issue", calls)
        self.assertRegex(self.issue_lines()[0], r"^- issue: #40 The badge is yellow, opened \d+ h ago, untriaged\.$")
        self.assertRegex(self.issue_lines()[1], r"^- issue: #41 Topo cannot see the lights \(filed by Topo\), opened \d+ h ago, untriaged\.$")
        self.assertEqual(len(self.issue_lines()), 2)
        text = Bridge.received[-1]["body"]["text"]
        self.assertNotIn("SECRET-MARKER", text)
        self.assertNotIn("issue: #7", text, "the open PR is not an issue")
        self.assertEqual({k for k in self.state_file()["fired"] if k.startswith("issue")}, {"issue:40", "issue:41"})

    def test_an_untriaged_issue_is_said_again_only_after_the_repeat_window(self):
        s = self.scripted(prs=[], issues=[issue(40, "Stands")])
        self.run_pass(s)
        self.assertEqual(len(self.issue_lines()), 1)
        n = len(Bridge.received)
        self.run_pass(s)
        self.assertEqual(self.issue_lines(since=n), [], "said once inside REPEAT")
        n = len(Bridge.received)
        self.backdate()
        self.run_pass(s)
        self.assertEqual(len(self.issue_lines(since=n)), 1)
        self.assertIn("#40 Stands", self.issue_lines(since=n)[0])

    def test_a_triaged_issue_goes_quiet_and_stays_quiet_past_the_repeat_window(self):
        for how in ({"labels": ["triaged"]}, {"comments": 1}):
            with self.subTest(how):
                self.setUp()
                self.run_pass(self.scripted(prs=[], issues=[issue(40, "Later")]))
                self.assertEqual(len(self.issue_lines()), 1)
                n = len(Bridge.received)
                triaged = self.scripted(prs=[], issues=[issue(40, "Later", **{k: v for k, v in how.items() if k == "comments"},
                                                              labels=how.get("labels", ()))])
                self.run_pass(triaged)
                self.assertNotIn("issue:40", self.state_file()["fired"], "a triaged issue's key is forgotten")
                self.backdate()
                p, _ = self.run_pass(triaged)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(self.issue_lines(since=n), [], "nothing is said about a triaged issue past REPEAT")

    def test_a_closed_issue_is_forgotten_only_on_a_pass_that_read_the_list(self):
        self.run_pass(self.scripted(prs=[], issues=[issue(40, "Closing")]))
        self.assertIn("issue:40", self.state_file()["fired"])
        p, _ = self.run_pass(self.scripted(prs=[], issues_error="HTTP 502: Bad Gateway"))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("issue:40", self.state_file()["fired"], "an unread list is not an empty one")
        self.assertIn("could not read the open issues", Bridge.received[-1]["body"]["text"])
        self.run_pass(self.scripted(prs=[], issues=[]))
        self.assertNotIn("issue:40", self.state_file()["fired"])

    def test_a_failed_or_page_filling_issue_read_reports_nothing_off_it_and_the_pr_cleanup_keeps_issue_keys(self):
        self.run_pass(self.scripted(issues=[issue(40, "Kept")]))
        fired = {k: v for k, v in self.state_file()["fired"].items() if k.startswith("issue")}
        self.assertEqual(list(fired), ["issue:40"])

        p, calls = self.run_pass(self.scripted(issues=[issue(40, "Kept"), issue(44, "New")], issues_error="HTTP 502"))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("pr merge 7", calls, "the PR list was read whole")
        self.assertEqual(self.issue_lines(), [])
        self.assertIn("could not read the open issues: gh api graphql", Bridge.received[-1]["body"]["text"])
        self.assertEqual({k: v for k, v in self.state_file()["fired"].items() if k.startswith("issue:")}, fired)

        many = [issue(1000 + i, f"t{i}") for i in range(501)]
        p, calls = self.run_pass(self.scripted(issues=many))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("pr merge 7", calls)
        self.assertEqual(self.issue_lines(), [])
        self.assertIn("the open issue list runs past 5 pages of 100", Bridge.received[-1]["body"]["text"])
        self.assertEqual(calls.count("gh api graphql"), 5, "no sixth page is read")
        after = self.state_file()["fired"]
        self.assertEqual({k: v for k, v in after.items() if k.startswith("issue:")}, fired)
        self.assertIn("issues:page", after)

        p, calls = self.run_pass(self.scripted(issues=many))
        self.assertIn("issues:page", self.state_file()["fired"], "a PR read does not drop the page key")

        self.run_pass(self.scripted(issues=[issue(40, "Kept")]))
        self.assertNotIn("issues:page", self.state_file()["fired"], "a whole read ends the page condition")
        self.assertIn("issue:40", self.state_file()["fired"])

    def test_the_issue_list_is_read_page_by_page_on_the_cursor(self):
        issues = [issue(1000 + i, f"t{i}", comments=1 if 0 < i < 100 else 0) for i in range(150)]
        p, calls = self.run_pass(self.scripted(prs=[], issues=issues))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(calls.count("gh api graphql"), 2)
        self.assertIn("-f after=100", calls)
        lines = self.issue_lines()
        self.assertEqual(len(lines), 51, "both pages' untriaged issues are reported")
        self.assertIn("#1000 t0,", lines[0])
        self.assertIn("#1100 t100,", lines[1])
        self.assertIn("#1149 t149,", lines[-1])
        self.assertNotIn("issues:page", self.state_file()["fired"])

    def test_exactly_five_full_pages_is_whole_and_a_sixth_is_not(self):
        p, calls = self.run_pass(self.scripted(prs=[], issues=[issue(1000 + i) for i in range(500)]))
        self.assertEqual(calls.count("gh api graphql"), 5)
        self.assertEqual(len(self.issue_lines()), janitor.ISSUE_LINES)
        self.assertIn("440 more untriaged issues wait for the next pass.", Bridge.received[-1]["body"]["text"])
        self.assertNotIn("issues:page", self.state_file()["fired"])
        self.assertEqual(sum(k.startswith("issue:") for k in self.state_file()["fired"]), janitor.ISSUE_LINES)
        p, calls = self.run_pass(self.scripted(prs=[], issues=[issue(1000 + i) for i in range(501)]))
        self.assertEqual(calls.count("gh api graphql"), 5)
        self.assertIn("issues:page", self.state_file()["fired"])
        self.assertEqual(sum(k.startswith("issue:") for k in self.state_file()["fired"]), janitor.ISSUE_LINES, "no key dropped off an unwhole read")

    def test_the_paged_read_returns_every_issue_on_both_pages(self):
        from unittest import mock
        with open(self.script, "w") as f:
            json.dump(self.scripted(issues=[issue(1000 + i) for i in range(150)]), f)
        with mock.patch.dict(os.environ, self.env, clear=True):
            nodes, whole = janitor.Shell().open_issues()
        self.assertTrue(whole)
        self.assertEqual([n["number"] for n in nodes], [1000 + i for i in range(150)])
        self.assertEqual(self.calls().count("gh api graphql"), 2)

    def test_a_report_the_other_lines_fill_takes_no_issue_line_and_no_notice(self):
        drafts = [pr(number=100 + i, isDraft=True, headRefOid=f"{i:040d}") for i in range(199)]
        p, calls = self.run_pass(self.scripted(prs=drafts, issues=[issue(40, "One"), issue(41, "Two"), issue(42, "Three")]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(Bridge.received), 1)
        text = Bridge.received[-1]["body"]["text"].splitlines()[1:]
        self.assertEqual(len(text), janitor.PENDING_MAX)
        self.assertEqual(sum("a draft, untouched" in l for l in text), 199, "every PR line is kept")
        self.assertIn("swept worktree topo-old", "\n".join(text))
        self.assertEqual(self.issue_lines(), [])
        self.assertNotIn("wait for the next pass", "\n".join(text))
        self.assertNotIn("dropped", "\n".join(text))
        self.assertFalse([k for k in self.state_file()["fired"] if k.startswith("issue:")], "said on a pass with room")
        self.backdate()
        p, _ = self.run_pass(self.scripted(prs=drafts, issues=[issue(40, "One"), issue(41, "Two"), issue(42, "Three")], issues_error="HTTP 502"))
        self.assertEqual(len(Bridge.received[-1]["body"]["text"].splitlines()[1:]), janitor.PENDING_MAX)
        self.assertNotIn("could not read the open issues", Bridge.received[-1]["body"]["text"])
        self.assertNotIn("issues:read", self.state_file()["fired"])

    def test_an_issue_read_that_fails_again_after_one_that_answered_is_said(self):
        bad, good = self.scripted(prs=[], issues_error="HTTP 502"), self.scripted(prs=[], issues=[])
        self.run_pass(bad)
        self.assertIn("could not read the open issues", Bridge.received[-1]["body"]["text"])
        self.run_pass(good)
        self.assertNotIn("issues:read", self.state_file()["fired"])
        n = len(Bridge.received)
        self.run_pass(bad)
        self.assertTrue(any("could not read the open issues" in m["body"]["text"] for m in Bridge.received[n:]),
                        "a new failure inside REPEAT is said")

    def test_a_triaged_label_past_the_twentieth_is_read_and_a_label_list_with_more_is_skipped(self):
        self.assertIn("labels(first: 100) { nodes { name } pageInfo { hasNextPage } }", janitor.ISSUES_QUERY)
        many = [f"l{k}" for k in range(20)]
        s = self.scripted(prs=[], issues=[issue(40, "Twenty-one", labels=many + ["triaged"]),
                                          issue(41, "Too many", labels=[f"l{k}" for k in range(101)]),
                                          issue(42, "Plain")])
        p, calls = self.run_pass(s)
        self.assertEqual(p.returncode, 0, p.stderr)
        text = Bridge.received[-1]["body"]["text"]
        self.assertNotIn("#40", text, "the 21st label, triaged, is read")
        self.assertIn("1 open issue node came back malformed and was skipped: #41.", text)
        self.assertNotIn("issue: #41", text)
        self.assertEqual([l.split(",")[0] for l in self.issue_lines()], ["- issue: #42 Plain"])
        old = self.scripted(prs=[], issues=[issue(40, "Twenty-one", labels=many + ["triaged"])])
        with open(self.script, "w") as f:
            json.dump(old, f)
        from unittest import mock
        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(janitor, "ISSUES_QUERY", janitor.ISSUES_QUERY.replace("labels(first: 100)", "labels(first: 20)")):
            nodes, whole = janitor.Shell().open_issues()
        self.assertEqual(len(nodes[0]["labels"]["nodes"]), 20)
        wants, keep, bad = janitor.decide_issues(nodes, NOW)
        self.assertEqual((wants, bad), ([], ["#40"]), "read the old way, the issue is skipped, never called untriaged")

    def test_while_a_report_waits_on_the_bridge_step_six_queues_nothing(self):
        state = {"undelivered": [{"id": "earlier", "at": "2026-09-28T00:00Z", "lines": ["an earlier line"]}]}
        with open(self.state, "w") as f:
            json.dump(state, f)
        Bridge.status = 503
        drafts = [pr(number=100 + i, isDraft=True, headRefOid=f"{i:040d}") for i in range(49)]
        s = self.scripted(prs=drafts, issues_error="HTTP 502", worktrees="worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n")
        for i in range(4):
            if i:
                self.backdate()
            p, _ = self.run_pass(s)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn("issues:read: waits for the undelivered reports", p.stderr)
        queued = self.undelivered()
        self.assertEqual(queued[0], "an earlier line", "nothing dropped")
        self.assertEqual(sum("a draft, untouched" in l for l in queued), 4 * 49, "every PR line is queued")
        self.assertFalse([l for l in queued if "issue" in l or "dropped" in l], "no step-6 line is queued")
        self.assertNotIn("issues:read", self.state_file()["fired"])
        Bridge.status = 200
        self.run_pass(s)
        self.assertEqual(self.undelivered(), [])
        self.run_pass(s)
        self.assertIn("could not read the open issues", Bridge.received[-1]["body"]["text"], "said once the queue is clear")

    def test_eleven_malformed_nodes_name_ten_and_count_the_rest(self):
        self.run_pass(self.scripted(prs=[], issues=[dict(issue(i), title=None) for i in range(1, 12)]))
        self.assertIn("11 open issue nodes came back malformed and were skipped: "
                      + ", ".join(f"#{i}" for i in range(1, 11)) + " and 1 more.", Bridge.received[-1]["body"]["text"])

    def test_issue_lines_past_the_cap_are_unfired_and_said_on_the_next_pass(self):
        s = self.scripted(prs=[], issues=[issue(1000 + i, f"t{i}") for i in range(janitor.ISSUE_LINES + 10)])
        self.run_pass(s)
        first = self.issue_lines()
        self.assertEqual(len(first), janitor.ISSUE_LINES)
        self.assertIn("10 more untriaged issues wait for the next pass.", Bridge.received[-1]["body"]["text"])
        fired = {k for k in self.state_file()["fired"] if k.startswith("issue:")}
        self.assertEqual(fired, {f"issue:{1000 + i}" for i in range(janitor.ISSUE_LINES)}, "a line cut is not fired")
        self.run_pass(s)
        second = self.issue_lines()
        self.assertEqual(len(second), 10)
        self.assertIn(f"#{1000 + janitor.ISSUE_LINES} ", second[0])
        self.assertNotIn("wait for the next pass", Bridge.received[-1]["body"]["text"])

    def test_a_pass_over_the_line_cap_cuts_issue_lines_and_keeps_every_pr_line(self):
        drafts = [pr(number=100 + i, isDraft=True, headRefOid=f"{i:040d}") for i in range(195)]
        p, calls = self.run_pass(self.scripted(prs=drafts, issues=[issue(1000 + i, f"t{i}") for i in range(20)]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(Bridge.received), 1, "one message, nothing dropped")
        text = Bridge.received[-1]["body"]["text"].splitlines()[1:]
        self.assertEqual(sum("a draft, untouched" in l for l in text), 195, "every PR line is kept")
        self.assertIn("swept worktree topo-old", "\n".join(text))
        said = self.issue_lines()
        self.assertEqual(len(text), janitor.PENDING_MAX)
        self.assertEqual(len(said), janitor.PENDING_MAX - 195 - 2)
        self.assertEqual(text[-1], f"- {20 - len(said)} more untriaged issues wait for the next pass.")
        fired = {k for k in self.state_file()["fired"] if k.startswith("issue:")}
        self.assertEqual(fired, {f"issue:{1000 + i}" for i in range(len(said))}, "a line cut is not fired")
        self.assertNotIn("dropped", Bridge.received[-1]["body"]["text"])

    def test_no_issue_line_joins_a_queue_that_waits_on_the_bridge(self):
        s = self.scripted(prs=[pr(body="- [ ] device: phone")], issues=[issue(40, "A"), issue(41, "B")])
        Bridge.status = 503
        self.run_pass(s)
        queued = lambda: [l for l in self.undelivered() if l.startswith("issue:")]
        self.assertEqual(len(queued()), 2, "an empty queue takes the pass's issue lines")
        for _ in range(3):
            self.backdate()
            p, _ = self.run_pass(s)
            self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(queued()), 2, "a standing queue gains no issue line, past REPEAT or not")
        self.assertEqual(sum("Proof box" in l for l in self.undelivered()), 4, "PR lines still join it")
        self.assertIn("issue line(s) wait for the undelivered reports", p.stderr)
        Bridge.status = 200
        n = len(Bridge.received)
        self.run_pass(s)
        self.assertEqual(self.undelivered(), [])
        self.assertEqual(len(self.issue_lines(since=n)), 2, "the queue's own two, delivered; none added on the pass that emptied it")
        n = len(Bridge.received)
        self.run_pass(s)
        self.assertEqual(len(self.issue_lines(since=n)), 2, "the two held since are said once the queue is clear")

    def test_a_malformed_issue_node_is_noted_and_the_pass_still_cleans_up(self):
        self.run_pass(self.scripted(prs=[], issues=[issue(39, "Closing"), issue(40, "Good")]))
        self.assertIn("issue:39", self.state_file()["fired"])
        p, _ = self.run_pass(self.scripted(prs=[], issues=[issue(40, "Good"), dict(issue(41), title=None)]))
        self.assertEqual(p.returncode, 0, p.stderr)
        text = Bridge.received[-1]["body"]["text"]
        self.assertIn("1 open issue node came back malformed and was skipped: #41.", text)
        self.assertNotIn("stopped early", text)
        fired = self.state_file()["fired"]
        self.assertNotIn("issue:39", fired, "cleanup ran: the closed issue is forgotten")
        self.assertIn("issue:40", fired)
        self.assertIn("issues:node", fired)
        self.run_pass(self.scripted(prs=[], issues=[issue(39, "Back"), issue(40, "Good")]))
        self.backdate()
        p, _ = self.run_pass(self.scripted(prs=[], issues=[issue(40, "Good"), None]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("skipped: node 2.", Bridge.received[-1]["body"]["text"])
        self.assertNotIn("stopped early", Bridge.received[-1]["body"]["text"])
        self.assertIn("issue:39", self.state_file()["fired"], "a node with no number may be #39: its key stays")
        self.run_pass(self.scripted(prs=[], issues=[issue(40, "Good")]))
        self.assertNotIn("issues:node", self.state_file()["fired"])
        self.assertNotIn("issue:39", self.state_file()["fired"])

    def test_a_dry_run_prints_the_issue_lines_and_writes_no_state(self):
        p, calls = self.run_pass(self.scripted(prs=[], issues=[issue(40, "Dry")]), extra=["--dry-run"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r"- issue: #40 Dry, opened \d+ h ago, untriaged\.")
        self.assertEqual(Bridge.received, [])
        self.assertFalse(os.path.exists(self.state))

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
        fresh = os.path.join(self.work, "never", "state.json")
        self.state = fresh
        p, calls = self.run_pass(self.scripted(published="abc1234"), extra=["--dry-run"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(os.path.exists(os.path.dirname(fresh)), "a dry run made the state directory")

    def test_the_install_page_is_republished_from_origin_main_and_a_failure_is_reported_with_its_tail(self):
        p, calls = self.run_pass(self.scripted(published="abc1234", publish_exit=1))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("publish-topo.sh origin/main", calls)
        text = Bridge.received[0]["body"]["text"]
        self.assertIn("failed", text)
        self.assertIn("fake publish", text)
        self.assertIn(LONG_MAIN, self.state_file()["publish"])
        p, calls = self.run_pass(self.scripted(published="abc1234", publish_exit=1))
        self.assertNotIn("publish-topo.sh", calls, "a failed publish waits out the retry")

    def test_the_rerun_key_and_the_lines_are_on_disk_before_the_publish_runs(self):
        snap = os.path.join(self.work, "state-at-publish.json")
        s = self.scripted(published="abc1234", publish_snapshot=snap,
                          prs=[pr(), pr(number=8, headRefOid="feedface0")],
                          runs={HEAD: [run()], "feedface0": [run("failure", number=8)]},
                          jobs=jobs(topo_unit="success", others="success", topo_ui="success", reviewer_ran="failure"))
        p, calls = self.run_pass(s)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("publish-topo", calls)
        with open(snap) as f:
            at_publish = json.load(f)
        self.assertIn("8:feedface0", at_publish["rerun"])
        self.assertTrue(any("merged #7" in l for l in at_publish["pending"]))
        self.assertTrue(any("reran the failed jobs of #8" in l for l in at_publish["pending"]))
        self.assertIsNone(at_publish["publish"][LONG_MAIN]["ok"], "the publish is recorded as begun before it runs")
        self.assertTrue(self.state_file()["publish"][LONG_MAIN]["ok"])

    def test_a_pass_killed_under_the_publish_has_saved_and_does_nothing_twice(self):
        s = self.scripted(published="abc1234", publish_hang=30)
        with open(self.script, "w") as f:
            json.dump(s, f)
        proc = subprocess.Popen([sys.executable, SCRIPT, "--state", self.state, "--checkout", "/r/topo"],
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        import time
        deadline = time.time() + 20
        while time.time() < deadline and "publish-topo" not in self.calls():
            time.sleep(0.1)
        self.assertIn("publish-topo", self.calls(), "the publish never started")
        proc.send_signal(15)
        out, err = proc.communicate(timeout=20)
        self.assertNotEqual(proc.returncode, -15, "SIGTERM was not turned into an ordinary exit")
        state = self.state_file()
        self.assertEqual((state["pending"], state["undelivered"]), ([], []), "the report was delivered before the process ended: " + err)
        self.assertTrue(any("merged #7" in l for l in Bridge.received[-1]["body"]["text"].splitlines()))
        self.assertIn("stopped early: SystemExit", Bridge.received[-1]["body"]["text"])
        self.assertIsNone(state["publish"][LONG_MAIN]["ok"])
        Bridge.received = []
        p, calls = self.run_pass(self.scripted(published="abc1234", prs=[], worktrees="worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n"))
        self.assertNotIn("publish-topo", calls, "a publish that was begun is not begun again inside the retry")
        self.assertEqual(Bridge.received, [])

    def test_a_publish_that_gives_no_answer_is_recorded_and_not_tried_every_pass(self):
        s = self.scripted(published="abc1234", publish_hang=3)
        p, calls = self.run_pass(s, extra=["--publish-timeout", "0.5"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("gave no answer", Bridge.received[-1]["body"]["text"])
        self.assertIsNone(self.state_file()["publish"][LONG_MAIN]["ok"])
        p, calls = self.run_pass(self.scripted(published="abc1234", prs=[], worktrees="worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n"))
        self.assertNotIn("publish-topo", calls)

    def test_an_install_page_that_cannot_be_read_is_said_and_never_republished(self):
        p, calls = self.run_pass(self.scripted(page_down=True))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("publish-topo", calls)
        self.assertIn("could not check or publish the install page", Bridge.received[-1]["body"]["text"])
        self.assertNotIn("publish", self.state_file()["publish"])

    def test_a_pass_that_stops_on_an_error_still_delivers_what_it_did_and_saves(self):
        # A PR the list answers with no head is a KeyError, which nothing inside the pass expects.
        p, calls = self.run_pass(self.scripted(prs=[pr(), {"number": 8, "isDraft": False}]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("gh pr merge 7", calls)
        text = Bridge.received[-1]["body"]["text"]
        self.assertIn("merged #7", text)
        self.assertIn("the pass stopped early: KeyError", text)
        self.assertEqual((self.state_file()["pending"], self.undelivered()), ([], []))

    def test_no_verdict_is_rerun_once_and_the_second_red_names_the_failing_tests(self):
        j = jobs(test="failure", topo_unit=("failure", "Boot the simulator"), reviewer_ran="failure")
        log = "Test Case '-[TopoTests.EarTests testTheEarHears]' failed (0.1 seconds)."
        s = self.scripted(runs={HEAD: [run("failure")]}, jobs=j, log=log)
        p, calls = self.run_pass(s)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("gh run rerun 99 --repo samdu/topo --failed", calls)
        self.assertNotIn("pr merge", calls)
        p, calls = self.run_pass(s)
        self.assertNotIn("run rerun", calls)
        text = Bridge.received[-1]["body"]["text"]
        self.assertIn("red again", text)
        self.assertIn("TopoTests.EarTests.testTheEarHears", text)

    def test_a_genuine_test_failure_is_never_rerun(self):
        j = jobs(test="failure", topo_unit=("failure", TEST_STEP), reviewer_ran="failure")
        s = self.scripted(runs={HEAD: [run("failure")]}, jobs=j)
        for i in range(3):
            p, calls = self.run_pass(s)
            self.assertNotIn("run rerun", calls, f"pass {i + 1}")
            self.assertEqual(self.state_file().get("rerun"), {}, f"pass {i + 1}")

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
        self.assertNotIn("run rerun", calls)

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
        self.assertTrue(any("merged #7" in l for l in self.undelivered()))
        self.assertEqual(self.state_file()["pending"], [], "the lines moved from pending to the undelivered message")
        Bridge.status = 200
        p, _ = self.run_pass(self.scripted(prs=[], worktrees="worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n"))
        self.assertTrue(any("merged #7" in l for l in Bridge.received[-1]["body"]["text"].splitlines()))
        self.assertEqual(self.undelivered(), [])
        Bridge.status = 400
        p, _ = self.run_pass(self.scripted())
        self.assertIn("dropped", p.stderr)
        self.assertEqual(self.undelivered(), [])

    def test_a_bridge_that_answers_badly_keeps_the_report_and_the_state(self):
        Bridge.short_body = True
        p, _ = self.run_pass(self.scripted())
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("kept for the next pass", p.stderr)
        self.assertIn("IncompleteRead", p.stderr)
        state = self.state_file()
        self.assertTrue(any("merged #7" in l for l in self.undelivered()))
        self.assertEqual(len(Bridge.received), 1, "the bridge took the message before answering badly")
        first = Bridge.received[0]["body"]
        self.assertEqual(state["undelivered"][0]["id"], first["id"])
        Bridge.short_body = False
        # The next pass has something new to say: it is a second message, and
        # the first is sent again exactly as it was, so a receiver keying on
        # the id sees the first once and the second as new.
        p, calls = self.run_pass(self.scripted(prs=[pr(body="- [ ] device: phone")],
                                               worktrees="worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n"))
        self.assertNotIn("pr merge", calls)
        self.assertEqual(len(Bridge.received), 3)
        self.assertEqual(Bridge.received[1]["body"], first, "the retry is the same message, id and text")
        self.assertIn("Proof box", Bridge.received[2]["body"]["text"])
        self.assertNotIn("merged #7", Bridge.received[2]["body"]["text"])
        self.assertNotEqual(Bridge.received[2]["body"]["id"], first["id"])
        self.assertEqual(self.undelivered(), [])

    def test_no_peer_token_keeps_the_report(self):
        os.remove(self.mesh_env)
        p, _ = self.run_pass(self.scripted())
        self.assertIn("no BRIDGE_PEER_TOKEN", p.stderr)
        self.assertTrue(self.undelivered())
        self.assertEqual(Bridge.received, [])


if __name__ == "__main__":
    unittest.main()
