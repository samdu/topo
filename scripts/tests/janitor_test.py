"""scripts/janitor.py: the decisions over scripted readings, and whole passes
against a fake gh, git, tmux, curl and claude with buddy-prime's bridge played by a
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
    d = {"number": number, "title": title, "createdAt": ago(age), "updatedAt": ago(age),
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

    def test_a_draft_wants_nothing_however_old_and_whatever_its_run(self):
        self.assertEqual(janitor.decide_pr(pr(isDraft=True, updatedAt=ago(timedelta(minutes=5))), None, [], {}, NOW), [])
        self.assertEqual(janitor.decide_pr(pr(isDraft=True, updatedAt=ago(timedelta(days=3))), None, [], {}, NOW), [])
        self.assertEqual(janitor.decide_pr(pr(isDraft=True), run(), jobs(test="success"), {}, NOW), [])
        j = jobs(test="success", reviewer_ran="failure", review_gate="failure")
        self.assertEqual(janitor.decide_pr(pr(isDraft=True), run("failure"), j, {}, NOW), [], "a draft's missing verdict is not rerun")

    def test_a_pr_fingerprint_moves_with_the_pr_and_not_with_time_or_a_comment(self):
        j = jobs(test="success", reviewer_ran="success", review_gate="failure")
        fp = lambda p=None, r=None, jj=None, conds=("verdict",): janitor.pr_fingerprint(p or pr(), r or run("failure"), j if jj is None else jj, conds)
        same = fp()
        self.assertEqual(fp(pr(updatedAt=ago(timedelta(days=2)), title="renamed")), same, "a comment, an age and a title move nothing")
        self.assertEqual(fp(r=run("failure", since=timedelta(days=2))), same)
        self.assertEqual(fp(conds=("verdict", "idle")), same, "having sat is not a change")
        for what, other in (("a new commit", fp(pr(headRefOid="fffffff0000"))),
                            ("a box ticked", fp(pr(body="- [x] suite\n- [ ] device: phone"))),
                            ("a label", fp(pr(labels=[{"name": "automerge"}]))),
                            ("the review decision", fp(pr(reviewDecision="APPROVED"))),
                            ("the run's conclusion", fp(r=run("cancelled"))),
                            ("a check flipped", fp(jj=jobs(test="failure", reviewer_ran="success", review_gate="failure"))),
                            ("another condition", fp(conds=("verdict", "red")))):
            self.assertNotEqual(other, same, what)

    def test_an_issue_fingerprint_is_its_labels_and_its_updated_at(self):
        fp = lambda **kw: janitor.decide_issues([issue(1, **kw)], NOW)[0][0]["fp"]
        same = fp()
        self.assertEqual(fp(title="renamed", createdAt=ago(timedelta(hours=1))), same)
        self.assertNotEqual(fp(labels=["bug"]), same)
        self.assertNotEqual(fp(updatedAt=ago(timedelta(minutes=1))), same)
        wants, keep, bad = janitor.decide_issues([dict(issue(2), updatedAt=None), {k: v for k, v in issue(3).items() if k != "updatedAt"}], NOW)
        self.assertEqual((wants, bad), ([], ["#2", "#3"]), "an issue with no updated-at is malformed")

    def test_the_digest_names_prs_with_what_holds_and_issues_by_number(self):
        line = janitor.digest_line({"pr:12": "boxes", "pr:7": "verdict, idle", "issue:40": "", "issue:9": ""})
        self.assertEqual(line, "still standing, unchanged since it was said: #7 (verdict, idle), #12 (boxes); untriaged issues #9, #40.")
        self.assertEqual(janitor.digest_line({"issue:9": ""}, first=True),
                         "first pass with no record of what was said; standing now: untriaged issue #9.")
        many = janitor.digest_line({f"issue:{i}": "" for i in range(janitor.DIGEST_NAMES + 3)})
        self.assertIn(" and 3 more.", many)

    def test_a_state_file_of_the_wrong_shape_is_a_first_run(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "state.json")
            self.assertEqual(janitor.load_state(p), {})
            for text in ("{not json", "[1, 2]", "null", '"x"'):
                with open(p, "w") as f:
                    f.write(text)
                self.assertEqual(janitor.load_state(p), {}, text)
            with open(p, "w") as f:
                json.dump({"reported": {"pr:7": "abc"}, "seeded": {"prs": True}, "rerun": {"7:h": {}}, "fired": [], "pending": "x"}, f)
            self.assertEqual(janitor.load_state(p), {"rerun": {"7:h": {}}}, "a record that is not whole goes, and what was done stays")

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
        self.assertGreaterEqual(janitor.REPEAT, timedelta(hours=24))
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

    COMMITS = [("4245517", "Perf marks (#296)"), ("75af080", "The janitor reports an item once (#300)")]

    def test_each_action_is_one_allowed_gh_call_or_none(self):
        for action, labels in (("triaged", "triaged"), ("flake", "triaged,flake"), ("next", "triaged,next"), ("parked", "triaged,parked")):
            d = janitor.decide_triage(40, "A title", {"action": action, "reason": "because"}, self.COMMITS)
            self.assertEqual(d["argv"], ["gh", "issue", "edit", "40", "--repo", "samdu/topo", "--add-label", labels])
            self.assertTrue(janitor.allowed(d["argv"]))
            self.assertIn("#40 A title", d["text"])
        d = janitor.decide_triage(40, "A title", {"action": "ask", "reason": "a product call"}, self.COMMITS)
        self.assertEqual((d["argv"], d["text"]), (None, "triage: #40 A title is put to Sam: a product call"))
        d = janitor.decide_triage(40, "A title", {"action": "fixed", "reason": "r", "commit": "75af080"}, self.COMMITS)
        self.assertEqual(d["argv"][:8], ["gh", "issue", "close", "40", "--repo", "samdu/topo", "--reason", "completed"])
        self.assertIn("75af080 (The janitor reports an item once (#300))", d["argv"][-1])
        self.assertTrue(janitor.allowed(d["argv"]))

    def test_fixed_by_a_commit_the_model_was_not_shown_closes_nothing(self):
        for commit in ("deadbee", "", None, "75af", "7", ["75af080"], "75af080c0ffee", "75af080 "*2, "-75af080"):
            d = janitor.decide_triage(40, "t", {"action": "fixed", "reason": "r", "commit": commit}, self.COMMITS)
            self.assertEqual((d["action"], d["argv"]), ("refused", None), commit)
        d = janitor.decide_triage(40, "t", {"action": "fixed", "reason": "r"}, self.COMMITS)
        self.assertEqual(d["action"], "refused")
        d = janitor.decide_triage(40, "t", {"action": "fixed", "reason": "r", "commit": " 75af080\n"}, self.COMMITS)
        self.assertEqual(d["action"], "refused", "character for character: space round a listed hash is not that hash")
        d = janitor.decide_triage(40, "t", {"action": "fixed", "reason": "r", "commit": "75af080"}, self.COMMITS)
        self.assertEqual(d["action"], "fixed")

    def test_a_reason_that_quotes_the_body_is_withheld(self):
        body = "the token is ghp_abcdefghijklmnopqrstuvwxyz0123 and the code is 482913, at 14 Flat Street"
        body += " url=https://x.example/hook?key=sk-9f8e7d6c5b4a; pass:Tr0ub4dor"
        body += " passphrase correcthorse\u00adbatterystaple pw ab1\u200bcdefghijklmnop key a1b2c\u200b3d4e5\u200bf6a7b\u200b8c9d0 \ufeffp4$$w0rd!x pin is abc12! ok LEAKEDTOKENABCDEFGH"
        for leak in ("it holds ghp_abcdefghijklmnopqrstuvwxyz0123.", "code (482913) was pasted", "see `ghp_abcdefghijklmnopqrstuvwxyz0123`",
                     "See ghp_abcdefghijklmnopqrstuvwxyz0123/", "x482913x", "key sk-9f8e7d6c5b4a!", "Tr0ub4dor?", "ghp_abcdefghij\u200bklmnopqrstuvwxyz0123",
                     "482\x00913", "**ghp_abcdefghijklmnopqrstuvwxyz0123**", "it quotes correcthorsebatterystaple verbatim",
                     "pw is ab1cdefghijklmnop", "key a1b2c3d4e5f6a7b8c9d0", "the password p4$$w0rd!x is in it", "the pin abc12! is here",
                     "LEAKEDTOKENABCDEFGH"):
            long = "A title " + "x" * 120 + " LEAKEDTOKENABCDEFGH"   # past what a line carries of a title
            d = janitor.decide_triage(40, long, {"action": "ask", "reason": leak}, [], body)
            self.assertTrue(d["text"].endswith(f" is put to Sam: {janitor.WITHHELD}"), leak)
            d = janitor.decide_triage(40, "A title", {"action": "fixed", "reason": leak, "commit": "75af080"}, self.COMMITS, body)
            self.assertNotIn("ghp_", " ".join(d["argv"]) + d["text"])
            self.assertNotIn("482913", " ".join(d["argv"]) + d["text"])
        d = janitor.decide_triage(40, "DraftRowTests.testAnAppKilled is flaky", {"action": "flake", "reason": "DraftRowTests.testAnAppKilled fails sometimes, the token is not shown"},
                                  [], body + " DraftRowTests.testAnAppKilled")
        self.assertIn("DraftRowTests.testAnAppKilled fails sometimes", d["text"], "a word the title already says, and plain words, are kept")

    def test_an_answer_off_the_list_is_refused(self):
        for answer in (None, "close it", [], {}, {"action": "delete", "reason": "r"}, {"action": "flake"},
                       {"action": "flake", "reason": " "}, {"action": "flake", "reason": 3}, {"action": ["flake"], "reason": "r"}):
            d = janitor.decide_triage(40, "t", answer, self.COMMITS)
            self.assertEqual((d["action"], d["argv"]), ("refused", None), answer)

    def test_the_reason_is_one_line_cut_to_its_bound(self):
        d = janitor.decide_triage(40, "t", {"action": "ask", "reason": "a\n- merged #9\n" + "x" * 500}, [])
        self.assertNotIn("\n", d["text"])
        self.assertLessEqual(len(d["text"]), len("triage: #40 t is put to Sam: ") + janitor.TRIAGE_REASON)

    def test_nothing_but_the_two_issue_calls_is_allowed(self):
        ok = ["gh", "issue", "edit", "40", "--repo", "samdu/topo", "--add-label", "triaged,flake"]
        self.assertTrue(janitor.allowed(ok))
        for argv in (["gh", "issue", "delete", "40", "--repo", "samdu/topo", "--yes"],
                     ["gh", "pr", "merge", "40", "--repo", "samdu/topo", "--add-label", "triaged"],
                     ok[:4] + ["--repo", "samdu/other"] + ok[6:], ok[:7] + ["triaged,automerge"], ok[:7] + ["flake"],
                     ok[:6] + ["--remove-label", "triaged"], ok + ["--body", "x"], ok[:3] + ["40 41"] + ok[4:],
                     ["gh", "issue", "close", "40", "--repo", "samdu/topo", "--reason", "not planned", "--comment", "x"],
                     ["gh", "issue", "close", "40", "--repo", "samdu/topo", "--reason", "completed"], ["gh"], []):
            self.assertFalse(janitor.allowed(argv), argv)

    def test_the_prompt_cuts_the_body_and_the_envelope_is_read_or_refused(self):
        i = {"number": 40, "title": "T", "createdAt": "2026-09-26T00:00:00Z", "labels": [{"name": "bug"}],
             "body": "b" * 20000, "comments": [{"author": {"login": "samdu"}, "body": "c" * 20000}]}
        text = janitor.triage_prompt(i, self.COMMITS)
        self.assertLess(len(text), janitor.TRIAGE_BODY + janitor.TRIAGE_COMMENTS + 600)
        self.assertIn("75af080 The janitor reports an item once (#300)", text)
        self.assertEqual(janitor.read_answer(json.dumps({"is_error": False, "structured_output": {"action": "ask"}})), {"action": "ask"})
        for out in ("", "<html>", "[]", json.dumps({"is_error": True, "result": "Credit balance is too low"})):
            with self.assertRaises(RuntimeError):
                janitor.read_answer(out)

    def test_the_digest_marks_an_issue_put_to_sam(self):
        self.assertEqual(janitor.digest_line({"issue:40": "put to Sam", "issue:41": ""}),
                         "still standing, unchanged since it was said: untriaged issues #40 (put to Sam), #41.")

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
                self.assertTrue(all(janitor.NO_REPLY in t.splitlines()[0] for t in sent), "every message says no reply is read")
                self.assertNotIn("SendMessage", "".join(sent))
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
    if a[:2] == ["issue", "view"]:
        i = S.get("views", {}).get(a[2])
        if i is None: print("issue not found", file=sys.stderr); sys.exit(1)
        out(i)
    if a[:2] in (["issue", "edit"], ["issue", "close"]):
        if S.get("issue_snapshot"):
            import shutil; shutil.copy(os.environ["JANITOR_STATE"], S["issue_snapshot"])
        sys.exit(S.get("issue_exit", 0))
elif tool == "claude":
    asked = sys.stdin.read()
    with open(os.environ["FAKE_LOG"] + ".asked", "a") as f: f.write(asked + "\n=====\n")
    import re; n = re.match(r"Issue #(\d+)", asked).group(1)
    answer = S.get("answers", {}).get(n)
    if answer is None: print("Not logged in", file=sys.stderr); sys.exit(1)
    if answer == "stderr-only": print("failed while reading: " + asked, file=sys.stderr); sys.exit(1)
    if isinstance(answer, str): out(answer)
    print(json.dumps({"type": "result", "is_error": bool(answer.get("is_error")), "result": answer.get("result", ""), "structured_output": answer.get("object")}))
    sys.exit(answer.get("exit", 0))
elif tool == "git":
    if "log" in a: out(S.get("commits", ""))
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
        for tool in ("gh", "git", "tmux", "curl", "bash", "claude"):
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
        # Not a first run: both scopes read before, nothing said yet, and a digest just sent.
        self.seed = {"reported": {}, "seeded": {"prs": True, "issues": True}, "digest_at": datetime.now(timezone.utc).isoformat()}
        with open(self.state, "w") as f:
            json.dump(self.seed, f)
        self.env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], FAKE_LOG=self.log,
                        FAKE_SCRIPT=self.script, HOME=self.work, TOPO_JANITOR_DELIVER_URL=self.url,
                        TOPO_JANITOR_MESH_ENV=self.mesh_env, JANITOR_STATE=self.state,
                        TOPO_JANITOR_CLAUDE=os.path.join(self.bin, "claude"))

    def run_pass(self, script, extra=(), triage=False):
        """One pass; `calls` is what this pass ran, not every pass so far. The
        triage step is left out unless a test asks for it."""
        if not triage and "--triage" not in extra:
            extra = [*extra, "--no-triage"]
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

    def backdate(self, hours=25, digest=True):
        """Everything said, and the digest when `digest`, as if `hours` ago:
        the next pass is past REPEAT and past DIGEST."""
        state = self.state_file()
        at = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
        state["fired"] = {k: at for k in state.get("fired", {})}
        state["reported"] = {k: dict(v, at=at) for k, v in state.get("reported", {}).items()}
        if digest:
            state["digest_at"] = at
        with open(self.state, "w") as f:
            json.dump(state, f)

    def said(self, prefix):
        return {k for k in self.state_file()["reported"] if k.startswith(prefix)}

    def digests(self, since=0):
        return [l for m in Bridge.received[since:] for l in m["body"]["text"].splitlines() if "standing" in l]

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
        self.assertEqual(self.said("issue"), {"issue:40", "issue:41"})
        self.assertIn(janitor.NO_REPLY, text.splitlines()[0])

    QUIET = "worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n"

    def test_an_unchanged_issue_is_said_once_however_old_and_again_when_it_changes(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40, "Stands")])
        self.run_pass(s)
        self.assertEqual(len(self.issue_lines()), 1)
        n = len(Bridge.received)
        self.run_pass(s)
        self.backdate(hours=24 * 9, digest=False)
        self.run_pass(s)
        self.assertEqual(Bridge.received[n:], [], "a pass with nothing new sends nothing, nine days on")
        self.run_pass(self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40, "Stands", labels=["bug"])]))
        self.assertEqual(len(self.issue_lines(since=n)), 1, "a label is a change")
        n = len(Bridge.received)
        self.run_pass(self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40, "Stands", labels=["bug"], updatedAt=ago(timedelta(minutes=1)))]))
        self.assertEqual(len(self.issue_lines(since=n)), 1, "so is its updated-at")

    def view(self, number, title="x", labels=(), state="OPEN", body="the body", age=timedelta(hours=1)):
        return {"number": number, "title": title, "body": body, "state": state, "createdAt": ago(age), "updatedAt": ago(age),
                "labels": [{"name": l} for l in labels], "comments": []}

    def triage_lines(self, since=None):
        got = Bridge.received[-1:] if since is None else Bridge.received[since:]
        return [l for m in got for l in m["body"]["text"].splitlines() if l.startswith("- triage")]

    def asked(self):
        path = self.log + ".asked"
        if not os.path.exists(path):
            return ""
        with open(path) as f:
            return f.read()

    def test_a_pass_triages_each_untriaged_issue_with_one_allowed_call_and_says_what_it_did(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, commits="75af080\tThe badge stays green (#44)\n4245517\tPerf marks (#296)",
                          issues=[issue(40, "A test fails sometimes"), issue(41, "A crash"), issue(42, "An idea"), issue(43, "A note"),
                                  issue(44, "The badge is yellow"), issue(45, "Charge for it?"), issue(46, "Planned", labels=["triaged"]),
                                  issue(47, "Answered", comments=1)],
                          views={str(n): self.view(n, t, body="SECRET-MARKER") for n, t in
                                 ((40, "A test fails sometimes"), (41, "A crash"), (42, "An idea"), (43, "A note"),
                                  (44, "The badge is yellow"), (45, "Charge for it?"))},
                          answers={"40": {"object": {"action": "flake", "reason": "intermittent on CI"}},
                                   "41": {"object": {"action": "next", "reason": "a clear defect"}},
                                   "42": {"object": {"action": "parked", "reason": "an enhancement"}},
                                   "43": {"object": {"action": "triaged", "reason": "a record"}},
                                   "44": {"object": {"action": "fixed", "reason": "main has the fix", "commit": "75af080"}},
                                   "45": {"object": {"action": "ask", "reason": "a pricing decision"}}})
        p, calls = self.run_pass(s, triage=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        issue_calls = [l for l in calls.splitlines() if l.startswith("gh issue") and " view " not in l]
        self.assertEqual(issue_calls, [
            "gh issue edit 40 --repo samdu/topo --add-label triaged,flake",
            "gh issue edit 41 --repo samdu/topo --add-label triaged,next",
            "gh issue edit 42 --repo samdu/topo --add-label triaged,parked",
            "gh issue edit 43 --repo samdu/topo --add-label triaged",
            "gh issue close 44 --repo samdu/topo --reason completed --comment Closed by the janitor's triage as fixed on main by 75af080 (The badge stays green (#44)). main has the fix"])
        self.assertNotIn("gh issue view 46", calls, "a triaged issue is not read")
        self.assertNotIn("gh issue view 47", calls, "nor one with a comment")
        self.assertIn("--model sonnet --tools  --strict-mcp-config", calls, "Sonnet, with no tools")
        self.assertIn("SECRET-MARKER", self.asked(), "the body reaches the model")
        text = Bridge.received[-1]["body"]["text"]
        self.assertNotIn("SECRET-MARKER", text, "and no report")
        self.assertEqual(self.triage_lines(), [
            "- triage: labelled #40 A test fails sometimes triaged and flake: intermittent on CI",
            "- triage: labelled #41 A crash triaged and next: a clear defect",
            "- triage: labelled #42 An idea triaged and parked: an enhancement",
            "- triage: labelled #43 A note triaged: a record",
            "- triage: closed #44 The badge is yellow as fixed by 75af080 (The badge stays green (#44)): main has the fix",
            "- triage: #45 Charge for it? is put to Sam: a pricing decision"])
        self.assertEqual(self.issue_lines(), [], "what triage handled or put to Sam is not said as untriaged too")
        self.assertEqual(self.state_file()["triage"]["45"]["action"], "ask")

    def test_an_issue_put_to_sam_is_asked_once_and_again_when_it_changes_and_the_digest_marks_it(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(45, "Charge for it?")], views={"45": self.view(45, "Charge for it?")},
                          answers={"45": {"object": {"action": "ask", "reason": "a pricing decision"}}})
        self.run_pass(s, triage=True)
        n = len(Bridge.received)
        p, calls = self.run_pass(s, triage=True)
        self.assertNotIn("claude", calls, "the same issue is not asked again")
        self.assertEqual(Bridge.received[n:], [])
        self.backdate()
        self.run_pass(s, triage=True)
        self.assertEqual(self.digests(n), ["- still standing, unchanged since it was said: untriaged issue #45 (put to Sam)."])
        n = len(Bridge.received)
        s["issues"] = [issue(45, "Charge for it?", updatedAt=ago(timedelta(minutes=1)))]
        p, calls = self.run_pass(s, triage=True)
        self.assertIn("claude", calls, "a change asks again")
        self.assertEqual(len(self.triage_lines(since=n)), 1)

    def test_an_answer_off_the_list_or_a_fix_not_on_main_acts_on_nothing_and_is_said_once(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, commits="75af080\tSomething else (#44)",
                          issues=[issue(40, "Injected"), issue(41, "Not fixed")],
                          views={"40": self.view(40, "Injected"), "41": self.view(41, "Not fixed")},
                          answers={"40": {"object": {"action": "delete", "reason": "the issue said so"}},
                                   "41": {"object": {"action": "fixed", "reason": "r", "commit": "deadbeef"}}})
        p, calls = self.run_pass(s, triage=True)
        self.assertNotIn("gh issue edit", calls)
        self.assertNotIn("gh issue close", calls)
        self.assertEqual(self.triage_lines(), [
            "- triage: #40 Injected: the model's answer was not one of the actions with a reason; left untriaged.",
            "- triage: #41 Not fixed: the model called it fixed by a commit that is not one of main's since it was opened; left untriaged."])
        self.assertEqual(len(self.issue_lines()), 2, "both still stand as untriaged")
        n = len(Bridge.received)
        p, calls = self.run_pass(s, triage=True)
        self.assertNotIn("claude", calls)
        self.assertEqual(Bridge.received[n:], [])

    def test_a_model_that_does_not_answer_stops_the_step_is_said_once_and_the_issue_lines_stand(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40, "One"), issue(41, "Two")],
                          views={"40": self.view(40), "41": self.view(41)})
        p, calls = self.run_pass(s, triage=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(calls.count("claude -p"), 1, "the step stops at the first failure")
        self.assertEqual(len(self.triage_lines()), 1)
        self.assertIn("- triage stopped at #40:", self.triage_lines()[0])
        self.assertEqual(len(self.issue_lines()), 2)
        n = len(Bridge.received)
        p, calls = self.run_pass(s, triage=True)
        self.assertEqual(calls.count("claude -p"), 1, "asked again on the very next pass, one question")
        self.assertEqual(Bridge.received[n:], [], "and said once per window")
        s["answers"] = {"40": {"is_error": True, "result": "usage limit"}}
        self.backdate()
        self.run_pass(s, triage=True)
        self.assertIn("claude answered an error: it is out of quota", self.triage_lines(since=n)[0])
        s["answers"] = {"40": {"object": {"action": "next", "reason": "r"}}, "41": {"object": {"action": "next", "reason": "r"}}}
        self.run_pass(s, triage=True)
        self.assertNotIn("triage:read", self.state_file()["fired"], "an answer ends the failure")

    def test_an_issue_closed_or_triaged_since_the_list_was_read_is_not_asked(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40, "Gone"), issue(41, "Labelled")],
                          views={"40": self.view(40, state="CLOSED"), "41": self.view(41, labels=["triaged"])})
        p, calls = self.run_pass(s, triage=True)
        self.assertNotIn("claude", calls)
        self.assertNotIn("gh issue edit", calls)
        self.assertEqual(Bridge.received, [], "and is not said as untriaged either")

    def test_the_body_reaches_no_report_when_the_model_quotes_it(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, commits="75af080\tA fix (#40)", issues=[issue(40, "Leaky"), issue(41, "Leaky too")],
                          views={"40": self.view(40, "Leaky", body="key: SECRET-MARKER-0123456789"), "41": self.view(41, "Leaky too", body="pin 990217")},
                          answers={"40": {"object": {"action": "fixed", "commit": "75af080", "reason": "the body says SECRET-MARKER-0123456789"}},
                                   "41": {"object": {"action": "ask", "reason": "its pin is 990217."}}})
        p, calls = self.run_pass(s, triage=True)
        text = Bridge.received[-1]["body"]["text"]
        for secret in ("SECRET-MARKER", "990217"):
            self.assertNotIn(secret, text)
            self.assertNotIn(secret, calls.replace(self.asked(), ""))
            self.assertNotIn(secret, json.dumps(self.state_file()))
        self.assertEqual(text.count(janitor.WITHHELD), 2)
        self.assertIn(f"gh issue close 40 --repo samdu/topo --reason completed --comment Closed by the janitor's triage as fixed on main by 75af080 (A fix (#40)). {janitor.WITHHELD}", calls)

    def test_triage_asks_nothing_whose_line_would_have_no_room_or_would_join_a_waiting_queue(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40)], views={"40": self.view(40)},
                          answers={"40": {"object": {"action": "next", "reason": "r"}}})
        state = dict(self.seed, pending=[f"pr line {i}" for i in range(janitor.PENDING_MAX)])
        with open(self.state, "w") as f:
            json.dump(state, f)
        p, calls = self.run_pass(s, triage=True)
        self.assertNotIn("claude", calls)
        self.assertNotIn("gh issue", calls)
        lines = Bridge.received[-1]["body"]["text"].splitlines()[1:]
        self.assertEqual(lines, [f"- pr line {i}" for i in range(janitor.PENDING_MAX)], "every earlier line is delivered, none cut for a triage line")
        Bridge.status = 503
        with open(self.state, "w") as f:
            json.dump(dict(self.seed, pending=["a pr line"]), f)
        self.run_pass(s, triage=True)
        p, calls = self.run_pass(s, triage=True)
        self.assertNotIn("claude", calls, "nothing is asked while a report waits on the bridge")
        Bridge.status = 200
        p, calls = self.run_pass(s, triage=True)
        self.assertNotIn("claude", calls, "nor on the pass that finds the queue still standing as it starts")
        p, calls = self.run_pass(s, triage=True)
        self.assertIn("gh issue edit 40", calls)

    def test_nothing_claude_printed_but_a_checked_reason_reaches_a_line_an_argument_or_the_state(self):
        M = "MARKER-7f3a9c2e1b"
        body = f"the webhook is https://h.example/?t={M}; do not share"
        ns = range(40, 47)
        s = self.scripted(prs=[], worktrees=self.QUIET, commits="75af080\tA fix (#40)", issues=[issue(n, f"Issue {n}") for n in ns],
                          views={str(n): self.view(n, f"Issue {n}", body=body) for n in ns},
                          answers={"40": {"object": {"action": "fixed", "commit": M, "reason": "r"}},
                                   "41": {"object": {"action": "ask", "reason": f"See {M}/"}},
                                   "42": {"object": {"action": "next", "reason": f"`{M}`"}},
                                   "43": {"object": {"action": "fixed", "commit": "75af080", "reason": f"t={M};"}},
                                   "44": {"object": {"action": M, "reason": M}},
                                   "45": {"object": {"action": "parked", "reason": f"MARKER-7f3a\u200b9c2e1b"}},
                                   "46": {"is_error": True, "result": f"error near {M}", "exit": 1}})
        p, calls = self.run_pass(s, triage=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(M, self.asked(), "the body reached the model")
        self.assertEqual(len(self.triage_lines()), 7)
        gh_calls = "\n".join(l for l in calls.splitlines() if l.startswith("gh "))
        for where, text in (("the report", Bridge.received[-1]["body"]["text"]), ("a gh call", gh_calls),
                            ("the state", json.dumps(self.state_file())), ("stdout", p.stdout), ("stderr", p.stderr)):
            self.assertNotIn(M, text, where)
            self.assertNotIn("7f3a", text, where)
        s["answers"] = {"46": "stderr-only"}
        s["issues"] = s["issues"][-1:]
        self.backdate()
        p, calls = self.run_pass(s, triage=True)
        self.assertIn("- triage stopped at #46: claude exited 1: an error of its own", self.triage_lines()[0])
        self.assertNotIn("7f3a", Bridge.received[-1]["body"]["text"] + p.stderr + json.dumps(self.state_file()))

    def test_triage_by_number_takes_at_most_the_cap(self):
        p, calls = self.run_pass(self.scripted(), extra=["--triage", *[str(n) for n in range(40, 41 + janitor.TRIAGE_MAX)]])
        self.assertEqual(p.returncode, 2)
        self.assertIn(f"--triage takes at most {janitor.TRIAGE_MAX} issues", p.stderr)
        self.assertEqual(calls, "", "nothing is read or asked")

    def test_an_issue_commented_on_since_the_list_was_read_is_left_as_triaged_by_hand(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40, "Answered meanwhile")],
                          views={"40": dict(self.view(40), comments=[{"author": {"login": "samdu"}, "body": "planned in P9"}])},
                          answers={"40": {"object": {"action": "parked", "reason": "r"}}})
        p, calls = self.run_pass(s, triage=True)
        self.assertNotIn("claude", calls)
        self.assertNotIn("gh issue edit", calls)
        self.assertEqual(Bridge.received, [])

    def test_the_action_line_is_on_disk_before_the_call_that_does_it(self):
        snap = os.path.join(self.work, "at-the-edit.json")
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40, "Labelled")], views={"40": self.view(40, "Labelled")},
                          answers={"40": {"object": {"action": "next", "reason": "r"}}}, issue_snapshot=snap)
        self.run_pass(s, triage=True)
        with open(snap) as f:
            self.assertEqual(json.load(f)["pending"], ["triage: labelled #40 Labelled triaged and next: r"],
                             "a pass killed after the label still has its line to deliver")
        self.assertEqual(self.triage_lines(), ["- triage: labelled #40 Labelled triaged and next: r"], "and it is said once")

    def test_an_answer_is_recorded_under_the_fingerprint_of_the_issue_as_it_was_asked_about(self):
        later = ago(timedelta(minutes=2))
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(45, "Moved")], views={"45": dict(self.view(45, "Moved"), updatedAt=later)},
                          answers={"45": {"object": {"action": "ask", "reason": "q"}}})
        self.run_pass(s, triage=True)
        s["issues"] = [issue(45, "Moved", updatedAt=later)]
        n = len(Bridge.received)
        p, calls = self.run_pass(s, triage=True)
        self.assertNotIn("claude", calls, "the next list shows the issue as it was asked about, and it is not asked again")
        self.assertEqual([l for m in Bridge.received[n:] for l in m["body"]["text"].splitlines() if "triage" in l], [])

    def test_triage_by_number_changes_nothing_when_the_report_is_full_or_one_waits(self):
        s = self.scripted(views={"40": self.view(40)}, answers={"40": {"object": {"action": "next", "reason": "r"}}})
        with open(self.state, "w") as f:
            json.dump(dict(self.seed, pending=[f"pr line {i}" for i in range(janitor.PENDING_MAX)]), f)
        p, calls = self.run_pass(s, extra=["--triage", "40"])
        self.assertNotIn("claude", calls)
        self.assertNotIn("gh issue", calls)
        self.assertIn("triage: #40 and what follows are left", p.stderr)
        self.assertEqual(Bridge.received[-1]["body"]["text"].splitlines()[1:], [f"- pr line {i}" for i in range(janitor.PENDING_MAX)])
        with open(self.state, "w") as f:
            json.dump(dict(self.seed, undelivered=[{"id": "m1", "at": "2026-09-26T19:00Z", "lines": ["an earlier line"]}]), f)
        Bridge.status = 503
        p, calls = self.run_pass(s, extra=["--triage", "40"])
        self.assertNotIn("claude", calls)
        self.assertNotIn("gh issue", calls)

    def test_a_pass_asks_about_at_most_the_cap(self):
        ns = range(40, 40 + janitor.TRIAGE_MAX + 3)
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(n) for n in ns], views={str(n): self.view(n) for n in ns},
                          answers={str(n): {"object": {"action": "parked", "reason": "r"}} for n in ns})
        p, calls = self.run_pass(s, triage=True)
        self.assertEqual(calls.count("claude -p"), janitor.TRIAGE_MAX)
        self.assertEqual(len(self.issue_lines()), 3, "the rest stand as untriaged until their pass")

    def test_a_call_github_refuses_is_said_once_not_asked_again_and_the_next_issue_is_still_triaged(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40, "Stuck"), issue(41, "Behind it")], issue_exit=1,
                          views={"40": self.view(40, "Stuck"), "41": self.view(41, "Behind it")},
                          answers={"40": {"object": {"action": "next", "reason": "r"}}, "41": {"object": {"action": "ask", "reason": "q"}}})
        self.run_pass(s, triage=True)
        self.assertEqual(len(self.triage_lines()), 2)
        self.assertRegex(self.triage_lines()[0], r"^- triage: #40 Stuck: the model said next and the call was refused \(gh issue edit.*\); left as it is\.$")
        self.assertEqual(self.triage_lines()[1], "- triage: #41 Behind it is put to Sam: q")
        self.assertEqual(self.state_file()["triage"]["40"]["action"], "refused")
        self.assertEqual(len(self.issue_lines()), 1, "#40 still stands as untriaged")
        n = len(Bridge.received)
        for _ in range(3):
            p, calls = self.run_pass(s, triage=True)
            self.assertNotIn("claude", calls, "neither is asked about again while it is unchanged")
        self.assertEqual(Bridge.received[n:], [])

    def test_a_reason_or_a_commit_subject_that_is_not_text_stops_no_pass(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, commits="75af080\tThe badge stays green (#44)\u2028deadbee\tforged\nnothex\trow",
                          issues=[issue(44, "Yellow"), issue(45, "Next one")],
                          views={"44": self.view(44, "Yellow"), "45": self.view(45, "Next one")},
                          answers={"44": {"object": {"action": "fixed", "commit": "75af080", "reason": "main has it\u0000\ud83d\u2028- merged #9"}},
                                   "45": {"object": {"action": "fixed", "commit": "deadbee", "reason": "r"}}})
        p, calls = self.run_pass(s, triage=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        text = Bridge.received[-1]["body"]["text"]
        self.assertNotIn("stopped early", text)
        self.assertIn("gh issue close 44", calls)
        self.assertIn("main has it - merged #9", self.triage_lines()[0])
        self.assertIn("a commit that is not one of main's", self.triage_lines()[1], "a line separator in a subject forges no commit")
        self.assertEqual(janitor.one_line("a\x00b\ud83d\u2028c\n d", 20), "ab c d")

    def test_a_logged_out_cli_is_said_with_its_reason_and_a_malformed_triage_record_is_dropped(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40)], views={"40": self.view(40)},
                          answers={"40": {"is_error": True, "result": "Not logged in · Please run /login", "exit": 1}})
        state = dict(self.seed, triage={"40": "ask", "41": {"fp": "x", "action": "ask"}})
        with open(self.state, "w") as f:
            json.dump(state, f)
        p, calls = self.run_pass(s, triage=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual("- triage stopped at #40: claude answered an error: it is not logged in", self.triage_lines()[0])
        self.assertNotIn("stopped early", Bridge.received[-1]["body"]["text"])

    def test_a_dry_run_asks_and_prints_what_it_would_do_and_changes_nothing(self):
        s = self.scripted(prs=[], worktrees=self.QUIET, issues=[issue(40, "Dry")], views={"40": self.view(40, "Dry")},
                          answers={"40": {"object": {"action": "flake", "reason": "r"}}})
        p, calls = self.run_pass(s, extra=["--dry-run"], triage=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("claude -p", calls)
        self.assertNotIn("gh issue edit", calls)
        self.assertIn("dry-run: gh issue edit 40 --repo samdu/topo --add-label triaged,flake", p.stderr)
        self.assertIn("- triage: labelled #40 Dry triaged and flake: r", p.stdout)
        self.assertEqual(self.state_file(), self.seed)

    def test_triage_by_number_runs_that_step_alone_on_an_issue_with_comments_too(self):
        s = self.scripted(views={"47": dict(self.view(47, "Answered"), comments=[{"author": {"login": "samdu"}, "body": "a second way"}]),
                                 "48": self.view(48, "Done", labels=["triaged"])},
                          answers={"47": {"object": {"action": "next", "reason": "r"}}})
        p, calls = self.run_pass(s, extra=["--triage", "47", "48"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("samdu: a second way", self.asked())
        self.assertEqual([l.split()[:3] for l in calls.splitlines() if l.startswith(("gh ", "tmux ", "curl ", "bash "))],
                         [["gh", "issue", "view"], ["gh", "issue", "edit"], ["gh", "issue", "view"]], "no PR, page or worktree is read")
        self.assertNotIn("worktree", calls)
        self.assertEqual(self.triage_lines(), ["- triage: labelled #47 Answered triaged and next: r",
                                               "- triage: #48 is triaged already; nothing done."])

    def test_an_unchanged_pr_is_said_once_and_again_only_when_it_changes(self):
        boxes = pr(body="- [ ] device: phone")
        s = self.scripted(prs=[boxes], worktrees=self.QUIET)
        self.run_pass(s)
        self.assertEqual(sum("Proof box" in r["body"]["text"] for r in Bridge.received), 1)
        n = len(Bridge.received)
        for hours in (3, 24, 48):
            self.backdate(hours=hours, digest=False)
            self.run_pass(self.scripted(prs=[dict(boxes, updatedAt=ago(timedelta(minutes=1)), title="a comment landed")], worktrees=self.QUIET))
        self.assertEqual(Bridge.received[n:], [], "three passes over two days, nothing changed, nothing sent")
        # A new commit; then a box ticked on it; then a check flipped.
        pushed = dict(boxes, headRefOid="feedface0")
        self.run_pass(self.scripted(prs=[pushed], runs={"feedface0": [run()]}, worktrees=self.QUIET))
        two = dict(pushed, body="- [ ] device: phone\n- [ ] device: watch")
        self.run_pass(self.scripted(prs=[two], runs={"feedface0": [run()]}, worktrees=self.QUIET))
        self.assertEqual([m["body"]["text"].count("Proof box") for m in Bridge.received[n:]], [1, 1])
        n = len(Bridge.received)
        red = self.scripted(prs=[two], runs={"feedface0": [run("failure")]}, worktrees=self.QUIET,
                            jobs=jobs(test="success", reviewer_ran="success", review_gate="failure"))
        self.run_pass(red)
        self.assertIn("the reviewer blocked", Bridge.received[-1]["body"]["text"])
        self.run_pass(red)
        self.assertEqual(len(Bridge.received), n + 1)
        self.assertEqual(self.said("pr:"), {"pr:7"})
        self.run_pass(self.scripted(prs=[], worktrees=self.QUIET))
        self.assertEqual(self.said("pr:"), set(), "a PR no longer open is forgotten")

    def test_a_pr_between_two_reports_is_not_said_again_for_the_same_state(self):
        j = jobs(test="success", reviewer_ran="success", review_gate="failure")
        red = self.scripted(runs={HEAD: [run("failure")]}, jobs=j, worktrees=self.QUIET)
        self.run_pass(red)
        n = len(Bridge.received)
        self.run_pass(self.scripted(runs={HEAD: [run(None, status="in_progress")]}, jobs=j, worktrees=self.QUIET))
        self.assertIn("pr:7", self.said("pr:"), "a run in progress forgets nothing")
        self.run_pass(red)
        self.assertEqual(Bridge.received[n:], [], "red, rerun by hand, red the same: said once")

    def test_a_draft_is_never_read_or_said(self):
        s = self.scripted(prs=[pr(isDraft=True, updatedAt=ago(timedelta(days=2)))], worktrees=self.QUIET)
        p, calls = self.run_pass(s)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("head_sha", calls, "a draft's runs are not read")
        self.assertEqual(Bridge.received, [])
        self.assertEqual(self.said("pr:"), set())

    def test_one_digest_a_day_names_what_still_stands_and_none_when_nothing_does(self):
        s = self.scripted(prs=[pr(body="- [ ] device: phone")], worktrees=self.QUIET, issues=[issue(40, "Stands")])
        self.run_pass(s)
        n = len(Bridge.received)
        self.backdate(hours=23)
        self.run_pass(s)
        self.assertEqual(Bridge.received[n:], [], "inside the day, nothing")
        self.backdate(hours=25)
        self.run_pass(s)
        self.run_pass(s)
        self.assertEqual(len(Bridge.received), n + 1, "one message, and the pass after it is quiet")
        self.assertEqual(Bridge.received[-1]["body"]["text"].splitlines()[1:],
                         ["- still standing, unchanged since it was said: #7 (boxes); untriaged issue #40."])
        n = len(Bridge.received)
        self.backdate(hours=25)
        self.run_pass(self.scripted(prs=[pr(body="- [ ] device: phone", headRefOid="feedface0")], runs={"feedface0": [run()]},
                                    worktrees=self.QUIET, issues=[issue(40, "Stands")]))
        lines = Bridge.received[-1]["body"]["text"].splitlines()[1:]
        self.assertEqual(len(lines), 2, "the PR's own line, and a digest that leaves out what was just said")
        self.assertIn("still standing, unchanged since it was said: untriaged issue #40.", lines[1])
        n = len(Bridge.received)
        self.backdate(hours=25)
        self.run_pass(self.scripted(prs=[], worktrees=self.QUIET))
        self.assertEqual(Bridge.received[n:], [], "nothing stands, no digest")

    def first_run(self, write):
        s = self.scripted(prs=[pr(body="- [ ] device: phone"), pr(number=8, headRefName="buddy/y", headRefOid="feedface0")],
                          worktrees=self.QUIET, issues=[issue(40 + i, f"t{i}") for i in range(70)])
        write()
        p, _ = self.run_pass(s)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(Bridge.received), 1)
        lines = Bridge.received[0]["body"]["text"].splitlines()[1:]
        self.assertEqual(len(lines), 1, "a first run is one digest line, whatever it finds")
        self.assertTrue(lines[0].startswith("- first pass with no record of what was said; standing now: #7 (boxes), #8 (norun); untriaged issues #40, #41,"))
        self.assertIn(" and 30 more.", lines[0])
        self.assertEqual(len(self.said("issue:")), 70, "every one is recorded, past the cap of a pass's issue lines")
        self.assertEqual(self.said("pr:"), {"pr:7", "pr:8"})
        self.run_pass(s)
        self.assertEqual(len(Bridge.received), 1, "and the pass after it is quiet")

    def test_a_missing_state_file_is_a_first_run_capped_at_a_digest(self):
        self.first_run(lambda: os.remove(self.state))

    def test_a_corrupt_state_file_is_a_first_run_capped_at_a_digest(self):
        def garbage():
            with open(self.state, "w") as f:
                f.write('{"reported": {"pr:7": {"fp": "tr')
        self.first_run(garbage)

    def test_a_state_file_from_before_the_record_keeps_what_was_done_and_is_a_first_run(self):
        def old():
            with open(self.state, "w") as f:
                json.dump({"fired": {f"7:boxes:{HEAD}": ago(timedelta(hours=1)), "issue:40": ago(timedelta(hours=1))},
                           "rerun": {f"7:{HEAD}": {"run": 99}}, "publish": {}, "pending": [], "undelivered": []}, f)
        self.first_run(old)
        self.assertIn(f"7:{HEAD}", self.state_file()["rerun"])
        self.assertNotIn("issue:40", self.state_file()["fired"])

    def test_a_first_run_whose_issue_read_failed_caps_the_issues_when_they_are_read(self):
        os.remove(self.state)
        issues = [issue(40, "A"), issue(41, "B")]
        self.run_pass(self.scripted(prs=[], worktrees=self.QUIET, issues=issues, issues_error="HTTP 502"))
        self.assertEqual(self.issue_lines(), [])
        n = len(Bridge.received)
        self.run_pass(self.scripted(prs=[], worktrees=self.QUIET, issues=issues))
        self.assertEqual(self.issue_lines(since=n), [])
        self.assertEqual(self.digests(since=n), ["- first pass with no record of what was said; standing now: untriaged issues #40, #41."])

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
                self.assertNotIn("issue:40", self.said("issue"), "a triaged issue's record is forgotten")
                self.backdate()
                p, _ = self.run_pass(triaged)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(self.issue_lines(since=n), [], "nothing is said about a triaged issue past REPEAT")

    def test_a_closed_issue_is_forgotten_only_on_a_pass_that_read_the_list(self):
        self.run_pass(self.scripted(prs=[], issues=[issue(40, "Closing")]))
        self.assertIn("issue:40", self.said("issue"))
        p, _ = self.run_pass(self.scripted(prs=[], issues_error="HTTP 502: Bad Gateway"))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("issue:40", self.said("issue"), "an unread list is not an empty one")
        self.assertIn("could not read the open issues", Bridge.received[-1]["body"]["text"])
        self.run_pass(self.scripted(prs=[], issues=[]))
        self.assertNotIn("issue:40", self.said("issue"))

    def test_a_failed_or_page_filling_issue_read_reports_nothing_off_it_and_the_pr_cleanup_keeps_issue_keys(self):
        self.run_pass(self.scripted(issues=[issue(40, "Kept")]))
        fired = {k: v for k, v in self.state_file()["reported"].items() if k.startswith("issue:")}
        self.assertEqual(list(fired), ["issue:40"])

        p, calls = self.run_pass(self.scripted(issues=[issue(40, "Kept"), issue(44, "New")], issues_error="HTTP 502"))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("pr merge 7", calls, "the PR list was read whole")
        self.assertEqual(self.issue_lines(), [])
        self.assertIn("could not read the open issues: gh api graphql", Bridge.received[-1]["body"]["text"])
        self.assertEqual({k: v for k, v in self.state_file()["reported"].items() if k.startswith("issue:")}, fired)

        many = [issue(1000 + i, f"t{i}") for i in range(501)]
        p, calls = self.run_pass(self.scripted(issues=many))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("pr merge 7", calls)
        self.assertEqual(self.issue_lines(), [])
        self.assertIn("the open issue list runs past 5 pages of 100", Bridge.received[-1]["body"]["text"])
        self.assertEqual(calls.count("gh api graphql"), 5, "no sixth page is read")
        self.assertEqual({k: v for k, v in self.state_file()["reported"].items() if k.startswith("issue:")}, fired)
        self.assertIn("issues:page", self.state_file()["fired"])

        p, calls = self.run_pass(self.scripted(issues=many))
        self.assertIn("issues:page", self.state_file()["fired"], "a PR read does not drop the page key")

        self.run_pass(self.scripted(issues=[issue(40, "Kept")]))
        self.assertNotIn("issues:page", self.state_file()["fired"], "a whole read ends the page condition")
        self.assertIn("issue:40", self.said("issue"))

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
        self.assertEqual(len(self.said("issue:")), janitor.ISSUE_LINES)
        p, calls = self.run_pass(self.scripted(prs=[], issues=[issue(1000 + i) for i in range(501)]))
        self.assertEqual(calls.count("gh api graphql"), 5)
        self.assertIn("issues:page", self.state_file()["fired"])
        self.assertEqual(len(self.said("issue:")), janitor.ISSUE_LINES, "no record dropped off an unwhole read")

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
        drafts = [pr(number=100 + i, headRefOid=f"{i:040d}") for i in range(199)]
        p, calls = self.run_pass(self.scripted(prs=drafts, issues=[issue(40, "One"), issue(41, "Two"), issue(42, "Three")]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(Bridge.received), 1)
        text = Bridge.received[-1]["body"]["text"].splitlines()[1:]
        self.assertEqual(len(text), janitor.PENDING_MAX)
        self.assertEqual(sum("ready with no validate run" in l for l in text), 199, "every PR line is kept")
        self.assertIn("swept worktree topo-old", "\n".join(text))
        self.assertEqual(self.issue_lines(), [])
        self.assertNotIn("wait for the next pass", "\n".join(text))
        self.assertNotIn("dropped", "\n".join(text))
        self.assertFalse(self.said("issue:"), "said on a pass with room")
        again = [dict(d, body="- [x] suite\n- [ ] device: phone") for d in drafts]   # every PR changed: 199 lines again
        gone = self.scripted(prs=again, issues=[issue(40, "One"), issue(41, "Two"), issue(42, "Three")], issues_error="HTTP 502")
        gone["worktrees"] = ("worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n"
                             f"worktree {self.work}/wt/gone\nHEAD 2222\nbranch refs/heads/buddy/gone\n\n")   # the 200th line
        gone["history"] = {"buddy/gone": [{"number": 5, "state": "MERGED", "mergedAt": ago(timedelta(hours=30)), "headRefOid": "2222"}]}
        p, _ = self.run_pass(gone)
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
        state.update(self.seed)
        with open(self.state, "w") as f:
            json.dump(state, f)
        s = None
        for i in range(4):
            # Each pass the PRs have a new head, so each pass has its PR lines to queue.
            drafts = [pr(number=100 + j, headRefOid=f"{i}{j:039d}") for j in range(49)]
            s = self.scripted(prs=drafts, issues_error="HTTP 502", worktrees="worktree /r/topo\nHEAD 1111\nbranch refs/heads/main\n\n")
            p, _ = self.run_pass(s)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn("issues:read: waits for the undelivered reports", p.stderr)
        queued = self.undelivered()
        self.assertEqual(queued[0], "an earlier line", "nothing dropped")
        self.assertEqual(sum("ready with no validate run" in l for l in queued), 4 * 49, "every PR line is queued")
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
        self.assertEqual(self.said("issue:"), {f"issue:{1000 + i}" for i in range(janitor.ISSUE_LINES)}, "a line cut is not recorded")
        self.run_pass(s)
        second = self.issue_lines()
        self.assertEqual(len(second), 10)
        self.assertIn(f"#{1000 + janitor.ISSUE_LINES} ", second[0])
        self.assertNotIn("wait for the next pass", Bridge.received[-1]["body"]["text"])

    def test_a_pass_over_the_line_cap_cuts_issue_lines_and_keeps_every_pr_line(self):
        drafts = [pr(number=100 + i, headRefOid=f"{i:040d}") for i in range(195)]
        p, calls = self.run_pass(self.scripted(prs=drafts, issues=[issue(1000 + i, f"t{i}") for i in range(20)]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(Bridge.received), 1, "one message, nothing dropped")
        text = Bridge.received[-1]["body"]["text"].splitlines()[1:]
        self.assertEqual(sum("ready with no validate run" in l for l in text), 195, "every PR line is kept")
        self.assertIn("swept worktree topo-old", "\n".join(text))
        said = self.issue_lines()
        self.assertEqual(len(text), janitor.PENDING_MAX)
        self.assertEqual(len(said), janitor.PENDING_MAX - 195 - 2)
        self.assertEqual(text[-1], f"- {20 - len(said)} more untriaged issues wait for the next pass.")
        self.assertEqual(self.said("issue:"), {f"issue:{1000 + i}" for i in range(len(said))}, "a line cut is not recorded")
        self.assertNotIn("dropped", Bridge.received[-1]["body"]["text"])

    def test_no_issue_line_joins_a_queue_that_waits_on_the_bridge(self):
        s = self.scripted(prs=[pr(body="- [ ] device: phone")], issues=[issue(40, "A"), issue(41, "B")])
        Bridge.status = 503
        self.run_pass(s)
        queued = lambda: [l for l in self.undelivered() if l.startswith("issue:")]
        self.assertEqual(len(queued()), 2, "an empty queue takes the pass's issue lines")
        for i in range(3):
            s = self.scripted(prs=[pr(body="- [ ] device: phone", headRefOid=f"feedface{i}")], runs={f"feedface{i}": [run()]},
                              issues=[issue(40, "A"), issue(41, "B"), issue(42, "C"), issue(43, "D")])
            p, _ = self.run_pass(s)
            self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(queued()), 2, "a standing queue gains no issue line")
        self.assertEqual(self.said("issue:"), {"issue:40", "issue:41"}, "and nothing is recorded of an issue not said")
        self.assertEqual(sum("Proof box" in l for l in self.undelivered()), 4, "PR lines still join it")
        self.assertIn("issue line(s) wait for the undelivered reports", p.stderr)
        Bridge.status = 200
        n = len(Bridge.received)
        self.run_pass(s)
        self.assertEqual(self.undelivered(), [])
        self.assertEqual(len(self.issue_lines(since=n)), 2, "the queue's own two, delivered; none added on the pass that emptied it")
        n = len(Bridge.received)
        self.run_pass(s)
        self.assertEqual([l.split(",")[0] for l in self.issue_lines(since=n)], ["- issue: #42 C", "- issue: #43 D"],
                         "the two held since are said once the queue is clear")

    def test_a_malformed_issue_node_is_noted_and_the_pass_still_cleans_up(self):
        self.run_pass(self.scripted(prs=[], issues=[issue(39, "Closing"), issue(40, "Good")]))
        self.assertIn("issue:39", self.said("issue:"))
        p, _ = self.run_pass(self.scripted(prs=[], issues=[issue(40, "Good"), dict(issue(41), title=None)]))
        self.assertEqual(p.returncode, 0, p.stderr)
        text = Bridge.received[-1]["body"]["text"]
        self.assertIn("1 open issue node came back malformed and was skipped: #41.", text)
        self.assertNotIn("stopped early", text)
        fired = self.state_file()["fired"]
        self.assertNotIn("issue:39", self.said("issue:"), "cleanup ran: the closed issue is forgotten")
        self.assertIn("issue:40", self.said("issue:"))
        self.assertIn("issues:node", fired)
        self.run_pass(self.scripted(prs=[], issues=[issue(39, "Back"), issue(40, "Good")]))
        self.backdate()
        p, _ = self.run_pass(self.scripted(prs=[], issues=[issue(40, "Good"), None]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("skipped: node 2.", Bridge.received[-1]["body"]["text"])
        self.assertNotIn("stopped early", Bridge.received[-1]["body"]["text"])
        self.assertIn("issue:39", self.said("issue:"), "a node with no number may be #39: its record stays")
        self.run_pass(self.scripted(prs=[], issues=[issue(40, "Good")]))
        self.assertNotIn("issues:node", self.state_file()["fired"])
        self.assertNotIn("issue:39", self.said("issue:"))

    def test_a_dry_run_prints_the_issue_lines_and_writes_no_state(self):
        p, calls = self.run_pass(self.scripted(prs=[], issues=[issue(40, "Dry")]), extra=["--dry-run"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r"- issue: #40 Dry, opened \d+ h ago, untriaged\.")
        self.assertEqual(Bridge.received, [])
        self.assertEqual(self.state_file(), self.seed, "a dry run writes no state")

    def test_a_dry_run_runs_nothing_and_prints_the_report(self):
        p, calls = self.run_pass(self.scripted(published="abc1234"), extra=["--dry-run"])
        self.assertEqual(p.returncode, 0, p.stderr)
        for verb in ("pr merge", "kill-session", "worktree remove", "publish-topo"):
            self.assertNotIn(verb, calls)
        self.assertIn("[topo-janitor] pass at", p.stdout)
        self.assertIn("merged #7", p.stdout)
        self.assertIn("republished the install page", p.stdout)
        self.assertEqual(Bridge.received, [])
        self.assertEqual(self.state_file(), self.seed, "a dry run writes no state")
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
