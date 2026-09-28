#!/usr/bin/env python3
"""topo-janitor — the mechanical upkeep of this repository's pipeline (docs/janitor.md).

    scripts/janitor.py              one pass: act, then report what it did or found
    scripts/janitor.py --dry-run    decide everything, run nothing, print the report
    scripts/janitor.py --verbose    also print what it left alone

One pass reads the open PRs, their newest validate run and its jobs, the
published install page and the checkout's worktrees, and does what needs no
judgement:

  1. merges a PR that meets every condition automerge.yaml merges on — ready,
     on main, its newest pull_request validate run green, no unchecked box in
     the description, the automerge label when the repository requires one —
     and that automerge has left unmerged for `GRACE`, pinned to the head the
     green run was read for;
  2. reruns the failed jobs of a red validate run once per head when the red
     is the infrastructure's: a suite job that failed before or after its
     tests ran (a setup step, an upload, a runner that gave no step), or the
     reviewer never ran (`reviewer_ran` red with every suite job green). A
     suite job whose tests, build or scripts failed is never rerun. The run
     has to be over for `SETTLE` and nothing in progress; red again after
     the rerun, it is reported with its failing jobs and tests;
  3. republishes the over-the-air install page when the commit it carries is
     not origin/main's;
  4. removes a linked worktree whose tip is exactly the head of a merged PR
     on its branch, merged more than `SWEEP` ago, with no PR open on the
     branch and nothing uncommitted — killing first any tmux session with a
     pane in it, then reading the tip again immediately before the remove —
     and deletes the branch ref only if it still names that merged head
     (`update-ref -d` with the old value), so a commit landing at any point
     is never dropped;
  5. reports, once per condition per head and again every `REPEAT` while it
     holds: a verdict that blocks, a draft untouched for `GRACE`, a green PR
     with Proof boxes unticked, a ready PR with no validate run, a run
     cancelled with nothing after it, and a PR nothing has touched for
     `IDLE` while no run is in progress;
  6. reports each open issue that is untriaged — no `triaged` label and no
     comment — once it is older than `GRACE`, again every `REPEAT` while it
     stays so. A paged GraphQL read (at most `ISSUES_PAGES` pages) gives the
     title, the labels and a comment count; the body is never read.

Everything it decides is a function of what it read; everything it does is a
`gh`, `git`, `tmux` or shell call behind `Shell`, so `--dry-run` prints the
pass instead. The report, when there is one, is posted to buddy-prime's mesh
bridge over the fleet's authenticated `/deliver` route with this host's own
peer token, as `topo-janitor` on the host `buddy-janitor`; a report the far
bridge does not take is kept in the state file and sent with the next. A
quiet pass sends nothing. Nothing here reads a review, merges over a red or
missing verdict, or edits code. One pass at a time: the state directory
holds a lock, and a pass that finds it held exits. The state file is written
after every action that changes the world — a merge, a rerun, a publish begun,
a sweep — and again as the pass ends, whatever ended it (a SIGTERM included),
so what was done is never done twice and what was said is never lost.

State: ~/.local/state/topo-janitor/state.json (override with --state).
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

REPO = "samdu/topo"
WORKFLOW = "pr-validate.yaml"
INSTALL_PAGE = "https://experiments.hexagon.zone/ota/files/623f17f9f38db5b81d0b/version.json"
PUBLISH = "~/github/experiments/ota/publish-topo.sh"
CHECKOUT = "~/github/topo"
MESH_DELIVER_URL = os.environ.get("TOPO_JANITOR_DELIVER_URL", "http://192.168.1.201/mesh/buddy-prime/deliver")
MESH_ENV = os.environ.get("TOPO_JANITOR_MESH_ENV", "~/.mesh-bridge-env")
MESH_SELF = "buddy-janitor"   # this host's verified mesh name; the sender below is the janitor's
REPORT_TO = "buddy-prime"
FROM = "topo-janitor"

GRACE = timedelta(minutes=15)      # automerge's chance, a draft's, a box's
SETTLE = timedelta(minutes=10)     # a red run is left this long before a rerun
IDLE = timedelta(minutes=45)       # nothing moving, nothing running
REPEAT = timedelta(minutes=180)    # a standing condition is said again after this
SWEEP = timedelta(hours=24)        # a merged branch's worktree lives this long
PUBLISH_RETRY = timedelta(hours=2)  # a publish is not tried again for one commit inside this
PUBLISH_KEEP = timedelta(days=7)   # publish records older than this are forgotten
PENDING_MAX = 200                  # report lines kept for a later delivery

UNCHECKED = re.compile(r"^\s*[-*] \[ \]", re.M)   # automerge.yaml's own test
SUITE_JOBS = ("topo_unit", "topo_ui", "others")
REVIEW_CHAIN = ("codex_wait", "codex", "post_feedback", "reviewer_ran", "review_gate")
# A suite job red at one of these steps, and no other, is the runner's own
# machinery failing around the PR's code: the simulator, the audio lane, a
# cache, a checkout or upload action. A red anywhere else in the job — the
# build, a fetch of pinned inputs, a script test, the tests, the step that
# counts them — is the code's, and is never rerun.
SETUP_STEPS = {
    "Set up job", "Boot the simulator", "Lane", "Audio loopback for the microphone test",
    "Cache the ear's models", "The ear's models for the microphone test", "Cache the manifest's files",
    "Clear Topo's privacy grants on the simulator", "Audio lane holds before the microphone test",
    "Audio lane holds after the microphone test", "Upload logs and result bundles", "Complete job",
}
SETUP_PREFIXES = ("Run actions/", "Post Run ", "Join the tailnet")
NOT_GREEN = ("failure", "cancelled", "timed_out")
ISSUES_PAGE = 100                  # issues read per GraphQL page
ISSUES_PAGES = 5                   # pages read before the list is taken as unwhole
ISSUE_LINES = 60                   # issue lines one pass says, so a report is mostly PR lines
TRIAGED = "triaged"                # buddy-prime has read it: planned, parked or put to Sam
FROM_TOPO = "from-topo"            # the mind on the phone filed it
ISSUES_QUERY = f"""query($owner: String!, $name: String!, $after: String) {{
  repository(owner: $owner, name: $name) {{
    issues(states: OPEN, first: {ISSUES_PAGE}, after: $after) {{
      pageInfo {{ hasNextPage endCursor }}
      nodes {{ number title createdAt labels(first: 20) {{ nodes {{ name }} }} comments {{ totalCount }} }}
    }}
  }}
}}"""


# --- time ------------------------------------------------------------------

def parse_time(s):
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


def minutes(td):
    m = int(td.total_seconds() // 60)
    if m >= 120:
        return f"{m // 60} h"
    return f"{m} min"


# --- pure decisions --------------------------------------------------------

def unchecked_boxes(body):
    return len(UNCHECKED.findall(body or ""))


def failing_tests(log, limit=5):
    """The test names an xcodebuild log says failed, first `limit` of them."""
    names = []
    for m in re.finditer(r"Test [Cc]ase '(-\[[^\]]+\]|[^']+)' failed", log):
        name = m.group(1).strip("-[]").replace(" ", ".")
        if name not in names:
            names.append(name)
    for m in re.finditer(r"^.*\berror: (.+)$", log, re.M):
        line = m.group(1).strip()
        if line and line not in names and len(names) < limit:
            names.append(line[:120])
    return names[:limit]


def parse_worktrees(porcelain):
    """`git worktree list --porcelain` as [{path, head, branch|None}]."""
    out, cur = [], {}
    for line in porcelain.splitlines() + [""]:
        if not line:
            if cur:
                out.append(cur)
            cur = {}
        elif line.startswith("worktree "):
            cur["path"] = line[len("worktree "):]
        elif line.startswith("HEAD "):
            cur["head"] = line[len("HEAD "):]
        elif line.startswith("branch "):
            cur["branch"] = line[len("branch "):].removeprefix("refs/heads/")
    return out


def infra_red(job):
    """Whether a red suite job failed in the infrastructure rather than the code:
    it concluded `failure` with no step of its own failing (the runner was lost),
    or every step that did not pass is a setup, lane or upload step. A step
    cancelled or timed out is not green; a job cancelled or timed out is not a
    failure of the infrastructure's kind. A failed build, test or script step
    is the code's."""
    if job.get("conclusion") != "failure":
        return False
    failed = [s["name"] for s in job.get("steps") or [] if s.get("conclusion") in NOT_GREEN]
    if not failed:
        return True
    return all(n in SETUP_STEPS or n.startswith(SETUP_PREFIXES) for n in failed)


def decide_pr(pr, run, jobs, state, now, require_label=False):
    """What one open PR wants from this pass.

    Returns a list of dicts: {"kind": merge|rerun|report, "key": ..., "text": ...}.
    `run` is the newest pull_request validate run for the PR's head, or None;
    `jobs` its jobs as [{name, conclusion, id, steps}]. Pure: nothing is read or done.
    """
    n, head = pr["number"], pr["headRefOid"]
    short = head[:7]
    title = f"#{n} ({pr['headRefName']})"
    age = now - parse_time(pr["updatedAt"])
    out = []

    def report(cond, text):
        out.append({"kind": "report", "key": f"{n}:{cond}:{head}", "text": text})

    if pr["isDraft"]:
        if age > GRACE:
            report("draft", f"{title}: a draft, untouched for {minutes(age)}; CI and the reviewer never run on a draft.")
        return out

    if run is None:
        if age > GRACE:
            report("norun", f"{title}: ready with no validate run for {minutes(age)}; a push starts one.")
        return out

    if run["status"] != "completed":
        return out

    concluded = parse_time(run.get("updated_at")) or (now - age)
    since = now - concluded
    conclusion = run.get("conclusion")

    if conclusion == "success":
        boxes = unchecked_boxes(pr.get("body"))
        if boxes:
            if since > GRACE:
                report("boxes", f"{title}: validate green for {minutes(since)}, {boxes} Proof box{'es' if boxes > 1 else ''} unticked; automerge waits on them.")
            return out
        labels = {l["name"] for l in pr.get("labels") or []}
        if require_label is None:
            report("label", f"{title}: validate green, but the repository's label rule could not be read; not merged.")
            return out
        if require_label and "automerge" not in labels:
            return out
        if pr.get("baseRefName") != "main":
            return out
        if since > GRACE:
            out.append({"kind": "merge", "key": f"{n}:merge:{head}", "head": head, "number": n,
                        "text": f"merged {title}: validate green, no unchecked box, and automerge had not fired after {minutes(since)}."})
        return out

    if conclusion == "cancelled":
        if since > GRACE:
            report("cancelled", f"{title}: its newest validate run was cancelled {minutes(since)} ago and nothing ran after it; a push starts one.")
        return out

    red = [j for j in jobs if j.get("conclusion") in NOT_GREEN]
    red_names = [j["name"] for j in red]
    suite_red = [j for j in red if j["name"] in SUITE_JOBS]
    # The verdict first, whatever else is red: the reviewer ran beside the
    # suites, so a blocking review and a suite red arrive on the same run.
    if "review_gate" in red_names and "reviewer_ran" not in red_names:
        report("verdict", f"{title}: the reviewer blocked {short}; the verdict is on the PR.")
    # No verdict: the reviewer chain is red and nothing outside it is — a red
    # `select`, `test` or suite job is the run's own failure, not the reviewer's.
    no_verdict = ("reviewer_ran" in red_names and all(j["name"] in REVIEW_CHAIN for j in red)
                  and not suite_red)
    # `test` is the gate and is red whenever a suite job is; the reviewer chain
    # waits on the suites. Any other red — `select`, a job this script does not
    # know — is the run's own, and no runner red beside it is rerun.
    others_red = [j["name"] for j in red if j["name"] not in SUITE_JOBS + ("test",) + REVIEW_CHAIN]
    infra_suite = bool(suite_red) and not others_red and all(infra_red(j) for j in suite_red)
    rerun_key = f"{n}:{head}"
    if infra_suite or no_verdict:
        why = ("the reviewer never ran (no verdict)" if no_verdict
               else f"a suite job failed outside its tests ({', '.join(j['name'] for j in suite_red)})")
        if rerun_key not in state.get("rerun", {}):
            if since > SETTLE:
                out.append({"kind": "rerun", "key": rerun_key, "run_id": run["id"], "number": n,
                            "text": f"reran the failed jobs of {title} (run {run['id']}): {why}."})
            return out
        detail = ", ".join(red_names) or conclusion
        report("red", f"{title}: red again on {short} after one rerun ({detail}); {why}.")
        return out

    if age > IDLE:
        detail = ", ".join(red_names) or conclusion
        report("idle", f"{title}: nothing has moved for {minutes(age)}; validate is {conclusion} ({detail}).")
    return out


def decide_issues(issues, now):
    """The open issues to report, and the numbers still untriaged.

    `issues` is the GraphQL read's nodes. An issue is untriaged while it has
    no `triaged` label and no comment; one is reported once it is older than
    GRACE. Returns (reports, keep, bad): a report is
    {"kind": "report", "key": "issue:N", "text": ...}; `keep` the numbers whose
    keys stand (the untriaged, and a malformed node's when it has a number),
    or None when a malformed node has no number to keep, so no issue key may
    be dropped; `bad` names each malformed node, which is skipped. Pure.
    """
    out, keep, bad = [], set(), []
    for at, i in enumerate(issues, 1):
        n = i.get("number") if isinstance(i, dict) else None
        if not isinstance(n, int) or isinstance(n, bool):
            n = None
        try:
            labels = {l["name"] for l in i["labels"]["nodes"]}
            comments = i["comments"]["totalCount"]
            title = i["title"]
            created = parse_time(i["createdAt"])
            if n is None or not isinstance(title, str) or not isinstance(comments, int) or created is None:
                raise ValueError
        except (KeyError, TypeError, ValueError, AttributeError):
            bad.append(f"#{n}" if n is not None else f"node {at}")
            if n is None:
                keep = None
            elif keep is not None:
                keep.add(n)
            continue
        if TRIAGED in labels or comments > 0:
            continue
        if keep is not None:
            keep.add(n)
        age = now - created
        if age <= GRACE:
            continue
        by = " (filed by Topo)" if FROM_TOPO in labels else ""
        out.append({"kind": "report", "key": f"issue:{n}",
                    "text": f"issue: #{n} {title}{by}, opened {minutes(age)} ago, untriaged."})
    return out, keep, bad


def decide_publish(published_commit, main_sha, state, now):
    """Whether to republish the install page. Returns a reason string or None."""
    if not main_sha:
        return None
    if published_commit and main_sha.startswith(published_commit):
        return None
    last = state.get("publish", {}).get(main_sha)
    if last:
        at = parse_time(last.get("at"))
        if at and now - at < PUBLISH_RETRY:
            return None  # a publish that succeeded is the pod still bouncing; one that failed waits
    return f"the page carries {published_commit or 'nothing'} and origin/main is {main_sha[:7]}"


def decide_sweep(worktrees, checkout, history, now):
    """Worktrees to remove: linked, on a branch with no open PR, whose tip is the
    very head a PR on that branch was merged at, more than SWEEP ago.

    `history(branch)` answers every PR ever opened from the branch as
    [{number, state, mergedAt, headRefOid}]. A branch name reused for a later
    PR, or a tip with commits past what was merged, matches nothing.
    """
    out = []
    for wt in worktrees:
        if os.path.realpath(wt["path"]) == os.path.realpath(checkout) or not wt.get("branch"):
            continue
        prs = history(wt["branch"]) or []
        if any(p.get("state") == "OPEN" for p in prs):
            continue
        merged = [p for p in prs if p.get("state") == "MERGED" and p.get("headRefOid") == wt.get("head")]
        if not merged:
            continue
        at = min(parse_time(p["mergedAt"]) for p in merged if p.get("mergedAt"))
        if now - at < SWEEP:
            continue
        out.append({"path": wt["path"], "branch": wt["branch"], "head": wt["head"], "number": merged[0]["number"], "age": now - at})
    return out


def due(state, key, now):
    """A report key is due when it has not fired inside REPEAT."""
    last = parse_time(state.get("fired", {}).get(key))
    return last is None or now - last >= REPEAT


# --- the shell -------------------------------------------------------------

class Shell:
    """Every process the janitor runs. `dry` runs nothing that changes anything.
    Every failure is a RuntimeError: a timeout, a non-zero exit, an answer that
    is not JSON."""

    def __init__(self, dry=False, log=None, publish_timeout=45 * 60):
        self.dry = dry
        self.log = log or (lambda s: print(s, file=sys.stderr, flush=True))
        self.publish_timeout = publish_timeout

    def run(self, argv, timeout=120, check=True, mutating=False, **kw):
        if mutating and self.dry:
            self.log(f"dry-run: {shlex.join(argv)}")
            return subprocess.CompletedProcess(argv, 0, "", "")
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, **kw)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"{shlex.join(argv[:3])}… gave no answer in {timeout} s")
        except OSError as ex:
            raise RuntimeError(f"{shlex.join(argv[:1])}: {ex}")
        if check and p.returncode != 0:
            raise RuntimeError(f"{shlex.join(argv[:3])}… exited {p.returncode}: {p.stderr.strip()[-400:]}")
        return p

    def gh_json(self, *args):
        out = self.run(["gh", *args]).stdout
        try:
            return json.loads(out or "null")
        except ValueError:
            raise RuntimeError(f"gh {shlex.join(args[:2])}… answered something that is not JSON")

    def gh_api(self, path, jq=None):
        args = ["api", path]
        if jq:
            args += ["--jq", jq]
        return self.gh_json(*args)

    def listed(self, limit, *args):
        """A `gh pr list` whose answer is shorter than its limit: one that fills
        the page may have left PRs off it, and is refused rather than read as whole."""
        prs = self.gh_json("pr", "list", "--repo", REPO, "--limit", str(limit), *args) or []
        if len(prs) >= limit:
            raise RuntimeError(f"gh pr list answered {len(prs)} PRs, its limit; the list may not be whole")
        return prs

    def open_prs(self):
        return self.listed(200, "--state", "open", "--json",
                           "number,title,isDraft,headRefName,headRefOid,updatedAt,body,baseRefName,labels")

    def require_label(self):
        """automerge.yaml's label rule: True, False, or None when it cannot be read
        (a variable that is not set reads as an error too, and means False)."""
        p = self.run(["gh", "variable", "get", "AUTOMERGE_REQUIRE_LABEL", "--repo", REPO], check=False)
        if p.returncode == 0:
            return p.stdout.strip() == "true"
        if "not found" in (p.stderr or "").lower():
            return False
        return None

    def newest_run(self, head, number):
        """The newest pull_request validate run for this head that GitHub ties to
        this PR: two PRs can share a head, and one's green run is not the other's."""
        runs = self.gh_api(f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?head_sha={head}&event=pull_request&per_page=100",
                           "[.workflow_runs[] | {id, status, conclusion, created_at, updated_at, prs: [.pull_requests[].number]}]") or []
        runs = [r for r in runs if number in (r.get("prs") or [])]
        runs.sort(key=lambda r: (r["created_at"], r["id"]))
        return runs[-1] if runs else None

    def jobs(self, run_id):
        return self.gh_api(f"repos/{REPO}/actions/runs/{run_id}/jobs?per_page=100",
                           "[.jobs[] | {id, name, conclusion, steps: [.steps[] | {name, conclusion}]}]") or []

    def job_log(self, job_id):
        p = self.run(["gh", "api", f"repos/{REPO}/actions/jobs/{job_id}/logs"], timeout=120, check=False)
        return p.stdout or ""

    def merge(self, number, head):
        self.run(["gh", "pr", "merge", str(number), "--repo", REPO, "--squash", "--delete-branch",
                  "--match-head-commit", head], mutating=True)

    def rerun(self, run_id):
        self.run(["gh", "run", "rerun", str(run_id), "--repo", REPO, "--failed"], mutating=True)

    def open_issues(self):
        """The open issues, as GraphQL nodes: number, title, createdAt, labels and a
        comment count, never a body. Read a page at a time on `endCursor`, at
        most ISSUES_PAGES pages; answers (nodes, whole), `whole` False when a
        next page still stands after the last one read."""
        owner, name = REPO.split("/")
        nodes, after = [], None
        for _ in range(ISSUES_PAGES):
            args = ["api", "graphql", "-f", f"query={ISSUES_QUERY}", "-F", f"owner={owner}", "-F", f"name={name}"]
            if after:
                args += ["-f", f"after={after}"]
            answer = self.gh_json(*args)
            try:
                issues = answer["data"]["repository"]["issues"]
                page, more, after = issues["nodes"], issues["pageInfo"]["hasNextPage"], issues["pageInfo"]["endCursor"]
            except (KeyError, TypeError):
                raise RuntimeError("gh api graphql answered without the repository's issues")
            if not isinstance(page, list):
                raise RuntimeError("gh api graphql answered without the repository's issues")
            nodes += page
            if not more:
                return nodes, True
            if not after:
                raise RuntimeError("gh api graphql said there is a next page and gave no cursor")
        return nodes, False

    def main_sha(self):
        return self.run(["gh", "api", f"repos/{REPO}/commits/main", "--jq", ".sha"]).stdout.strip()

    def published_commit(self):
        """The commit the install page carries; None when the page has none.
        A page that cannot be read is an error, not a page with nothing on it."""
        p = self.run(["curl", "-sS", "-f", "-m", "20", INSTALL_PAGE], check=False)
        if p.returncode != 0:
            raise RuntimeError(f"the install page did not answer: {p.stderr.strip()[-200:]}")
        try:
            return json.loads(p.stdout).get("commit")
        except (ValueError, AttributeError):
            raise RuntimeError("the install page's version.json is not JSON")

    def publish(self):
        script = os.path.expanduser(PUBLISH)
        p = self.run(["bash", script, "origin/main"], timeout=self.publish_timeout, check=False, mutating=True)
        return p.returncode == 0, (p.stdout + p.stderr)

    def worktrees(self, checkout):
        return parse_worktrees(self.run(["git", "-C", checkout, "worktree", "list", "--porcelain"]).stdout)

    def worktree_clean(self, path):
        return self.run(["git", "-C", path, "status", "--porcelain"]).stdout.strip() == ""

    def pr_history(self, branch):
        return self.listed(100, "--state", "all", "--head", branch, "--json", "number,state,mergedAt,headRefOid")

    def tmux_panes(self):
        """Every pane of every session as (session, current path)."""
        p = self.run(["tmux", "list-panes", "-a", "-F", "#{session_name}\t#{pane_current_path}"], check=False)
        if p.returncode != 0:
            if "no server running" in (p.stderr or ""):
                return []   # no tmux at all is no sessions to kill
            raise RuntimeError(f"tmux list-panes exited {p.returncode}: {p.stderr.strip()[-200:]}")
        return [tuple(l.split("\t", 1)) for l in p.stdout.splitlines() if "\t" in l]

    def kill_tmux(self, name):
        self.run(["tmux", "kill-session", "-t", f"={name}"], mutating=True)

    def tip(self, path):
        return self.run(["git", "-C", path, "rev-parse", "HEAD"]).stdout.strip()

    def remove_worktree(self, checkout, path):
        self.run(["git", "-C", checkout, "worktree", "remove", path], mutating=True)

    def delete_branch_at(self, checkout, branch, head):
        """Delete the branch ref only while it still names `head`: git refuses
        the update when the ref has moved, so a commit that landed is kept."""
        self.run(["git", "-C", checkout, "update-ref", "-d", f"refs/heads/{branch}", head], mutating=True)

    def post(self, url, body, token):
        """POST JSON with a bearer. Answers (status, text); raises RuntimeError
        when nothing answers."""
        req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.status, r.read().decode(errors="replace")[:200]
        except urllib.error.HTTPError as ex:
            try:
                return ex.code, ex.read().decode(errors="replace")[:200]
            except Exception as inner:  # noqa: BLE001 — a body that cannot be read is still the status
                return ex.code, f"(body unreadable: {inner})"[:200]
        except Exception as ex:  # noqa: BLE001 — a bridge answering badly is a delivery that did not happen
            raise RuntimeError(f"{type(ex).__name__}: {str(ex)[:160]}")


# --- the report ------------------------------------------------------------

def peer_token(path=MESH_ENV):
    """This host's own mesh peer token, from the bridge's env file
    (`export BRIDGE_PEER_TOKEN=…`). None when the file or the line is absent."""
    try:
        with open(os.path.expanduser(path)) as f:
            for line in f:
                line = line.strip()
                if line.startswith("export "):
                    line = line[len("export "):]
                if line.startswith("BRIDGE_PEER_TOKEN="):
                    return line.split("=", 1)[1].strip().strip("'\"") or None
    except OSError:
        return None
    return None


def deliver(sh, state, now, dry=False, log=print, warn=None):
    """The reports to buddy-prime, through its bridge's /deliver as the fleet's
    bridges forward to each other: this host's verified name as `from`, the
    janitor as `sender`. This pass's lines become one message under a new id;
    messages the bridge has not answered for good stand in `undelivered` under
    the ids they were first sent with, and go first, oldest first, each as the
    message it was — a bridge that took one and then answered badly is sent the
    same id and the same text, never a bigger message under that id. A 200
    settles a message, a 400 is the bridge refusing it for good (dropped, and
    said to have been), and anything else keeps it and every message after it.
    Of more than PENDING_MAX lines standing the oldest messages go, with a
    message of its own saying how many lines."""
    warn = warn or (lambda s: print(s, file=sys.stderr, flush=True))
    queue = list(state.get("undelivered", []))
    lines = list(state.get("pending", []))
    state["pending"] = []
    if lines:
        queue.append({"id": str(uuid.uuid4()), "at": now.strftime("%Y-%m-%dT%H:%MZ"), "lines": lines})
    dropped = 0
    while queue and sum(len(m["lines"]) for m in queue) > PENDING_MAX and len(queue) > 1:
        dropped += len(queue.pop(0)["lines"])
    if queue and len(queue[-1]["lines"]) > PENDING_MAX:
        dropped += len(queue[-1]["lines"]) - PENDING_MAX
        queue[-1]["lines"] = queue[-1]["lines"][-PENDING_MAX:]
    if dropped:
        # Said in a message of its own: a message already sent once is never
        # re-sent with different text under its id.
        queue.append({"id": str(uuid.uuid4()), "at": now.strftime("%Y-%m-%dT%H:%MZ"),
                      "lines": [f"{dropped} older line{'s' if dropped > 1 else ''} not delivered in time were dropped."]})
    state["undelivered"] = queue
    if not queue:
        return
    token = None if dry else peer_token(MESH_ENV)
    if not dry and not token:
        warn(f"report not delivered (no BRIDGE_PEER_TOKEN in {MESH_ENV}); kept for the next pass")
        return
    while queue:
        m = queue[0]
        text = f"[{FROM}] pass at {m['at']}\n" + "\n".join(f"- {l}" for l in m["lines"])
        if dry:
            log(text)
            queue.pop(0)
            continue
        body = {"id": m["id"], "from": MESH_SELF, "sender": FROM, "to": REPORT_TO, "text": text}
        try:
            status, answer = sh.post(MESH_DELIVER_URL, body, token)
        except RuntimeError as ex:
            warn(f"report not delivered ({ex}); kept for the next pass")
            break
        if status == 200:
            queue.pop(0)
        elif status == 400:
            warn(f"report refused for good by {REPORT_TO}'s bridge ({answer}); {len(m['lines'])} line(s) dropped")
            queue.pop(0)
        else:
            warn(f"report not delivered ({status} {answer}); kept for the next pass")
            break
    state["undelivered"] = queue


# --- one pass --------------------------------------------------------------

def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".state-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def run_pass(sh, state, now, checkout, persist=lambda: None, verbose=False):
    """One pass. What it did and found goes onto `state["pending"]` as it goes,
    and `persist()` writes the state after every action that changed the world,
    so a pass that stops early — an error, a signal mid-publish — has still
    recorded what it did and said before it stopped."""
    quiet = []
    state.setdefault("fired", {})
    state.setdefault("rerun", {})
    state.setdefault("publish", {})
    state.setdefault("pending", [])
    lines = state["pending"]

    def say(key, text):
        """A line that stands while its condition does: once per REPEAT."""
        if due(state, key, now):
            lines.append(text)
            state["fired"][key] = now.isoformat()
        else:
            quiet.append(f"{key}: said within the last {minutes(REPEAT)}")

    # 1, 2, 5: the open PRs.
    prs, prs_ok = [], False
    try:
        prs = sh.open_prs()
        prs_ok = True
        require_label = sh.require_label()
    except RuntimeError as ex:
        say("prs:read", f"could not read the open PRs: {ex}")
        require_label = None
    for pr in prs:
        n, head = pr["number"], pr["headRefOid"]
        try:
            run = jobs = None
            if not pr["isDraft"]:
                run = sh.newest_run(head, n)
                jobs = sh.jobs(run["id"]) if run and run["status"] == "completed" else []
            wants = decide_pr(pr, run, jobs or [], state, now, require_label)
        except RuntimeError as ex:
            say(f"{n}:read:{head}", f"#{n}: could not read its runs: {ex}")
            if "rate limit" in str(ex).lower():
                lines.append("GitHub is rate limiting; the rest of the PRs wait for the next pass.")
                break
            continue
        if not wants:
            quiet.append(f"#{n}: nothing to do")
        for w in wants:
            if w["kind"] == "merge":
                try:
                    sh.merge(w["number"], w["head"])
                    lines.append(w["text"])
                    persist()
                except RuntimeError as ex:
                    say(f"{n}:merge-refused:{head}", f"#{n}: merge refused: {ex}")
            elif w["kind"] == "rerun":
                try:
                    sh.rerun(w["run_id"])
                    state["rerun"][w["key"]] = {"run": w["run_id"], "at": now.isoformat()}
                    lines.append(w["text"])
                    persist()
                except RuntimeError as ex:
                    say(f"{n}:rerun-refused:{head}", f"#{n}: rerun refused: {ex}")
            else:
                text = w["text"]
                if ":red:" in w["key"] and due(state, w["key"], now):
                    names = []
                    for j in jobs or []:
                        if j.get("conclusion") == "failure" and j["name"] in SUITE_JOBS:
                            try:
                                names += failing_tests(sh.job_log(j["id"]))
                            except RuntimeError:
                                pass
                    if names:
                        text += " Failing: " + "; ".join(dict.fromkeys(names)) + "."
                say(w["key"], text)

    # 3: the install page.
    try:
        main_sha = sh.main_sha()
        published = sh.published_commit()
        why = decide_publish(published, main_sha, state, now)
        if why:
            # Recorded before it runs: a publish that times out, or a pass that
            # dies under it, is still an attempt, and is not made again until
            # PUBLISH_RETRY has passed.
            state["publish"][main_sha] = {"at": now.isoformat(), "ok": None}
            persist()
            ok, log = sh.publish()
            state["publish"][main_sha] = {"at": now.isoformat(), "ok": ok}
            if ok:
                lines.append(f"republished the install page at {main_sha[:7]}: {why}.")
            else:
                tail = " | ".join(l.strip() for l in log.strip().splitlines()[-6:])
                lines.append(f"republishing the install page at {main_sha[:7]} failed ({why}): {tail}")
            persist()
        else:
            quiet.append(f"install page: at {published}, main is {(main_sha or '')[:7]}")
    except RuntimeError as ex:
        say("publish:read", f"could not check or publish the install page: {ex}")

    # 4: worktrees whose tip is a merged PR's head.
    try:
        seen = {}

        def history(branch):
            if branch not in seen:
                seen[branch] = sh.pr_history(branch)
            return seen[branch]

        worktrees = sh.worktrees(checkout)
        candidates = []
        for wt in worktrees:
            try:
                candidates += decide_sweep([wt], checkout, history, now)
            except RuntimeError as ex:
                say(f"sweep:{wt['path']}", f"worktree {os.path.basename(wt['path'])} ({wt.get('branch')}): its PR history could not be read, left: {ex}")
        for wt in candidates:
            name = os.path.basename(wt["path"])
            key = f"sweep:{wt['path']}"
            try:
                if not sh.worktree_clean(wt["path"]):
                    say(key, f"worktree {name} ({wt['branch']}, #{wt['number']} merged {minutes(wt['age'])} ago) has uncommitted changes; left, with its sessions.")
                    continue
                # The branch is asked again before anything is killed: a PR
                # opened from it since the history was read makes this its
                # worktree, and its sessions, not a leftover.
                if any(p.get("state") == "OPEN" for p in sh.pr_history(wt["branch"])):
                    say(key, f"worktree {name} ({wt['branch']}) got an open PR while the sweep looked; left.")
                    continue
                root = wt["path"].rstrip("/")
                killed = sorted({s for s, cwd in sh.tmux_panes() if cwd == root or cwd.startswith(root + "/")})
                for s in killed:
                    sh.kill_tmux(s)
                # The tip is read again here, after every call that took time,
                # and the ref is deleted only while it still names that head:
                # a commit landing anywhere in between is kept.
                tip = sh.tip(wt["path"])
                if tip != wt["head"]:
                    say(key, f"worktree {name} ({wt['branch']}) moved to {tip[:7]} while the sweep looked; left.")
                    continue
                # And once more, right before the remove, for a PR opened while
                # the kills and the tip read took their time.
                if any(p.get("state") == "OPEN" for p in sh.pr_history(wt["branch"])):
                    say(key, f"worktree {name} ({wt['branch']}) got an open PR while the sweep looked; left, its sessions killed.")
                    continue
                sh.remove_worktree(checkout, wt["path"])
                try:
                    sh.delete_branch_at(checkout, wt["branch"], wt["head"])
                    kept = ""
                except RuntimeError:
                    kept = f"; the branch ref moved past {wt['head'][:7]} and is kept"
                tm = f"; killed tmux {', '.join(killed)}" if killed else ""
                lines.append(f"swept worktree {name} ({wt['branch']}, #{wt['number']} merged {minutes(wt['age'])} ago; its tip was the merged head){tm}{kept}.")
                persist()
            except RuntimeError as ex:
                say(key, f"worktree {name} ({wt['branch']}, #{wt['number']} merged) will not remove: {ex}")
    except RuntimeError as ex:
        say("sweep:read", f"could not read the worktrees: {ex}")

    # 6: the open issues nobody has triaged.
    # Issue lines are the first cut: the pass's PR lines come first, a pass
    # says at most ISSUE_LINES of them inside PENDING_MAX, and none while an
    # earlier report is undelivered, so a queue that waits on the bridge holds
    # PR lines rather than issue lines that are said again anyway. A line not
    # said leaves its key unfired, and it is said on a later pass.
    untriaged = None   # the keys that stand, known only off a whole read
    malformed = False
    try:
        issues, whole = sh.open_issues()
        if not whole:
            say("issues:page", f"the open issue list runs past {ISSUES_PAGES} pages of {ISSUES_PAGE}; no issue is reported off a list not read whole.")
        else:
            wants, untriaged, bad = decide_issues(issues, now)
            if bad:
                malformed = True
                say("issues:node", f"{len(bad)} open issue node{'s' if len(bad) > 1 else ''} came back malformed and {'were' if len(bad) > 1 else 'was'} skipped: {', '.join(bad[:10])}.")
            owed = [w for w in wants if due(state, w["key"], now)]
            quiet += [f"{w['key']}: said within the last {minutes(REPEAT)}" for w in wants if w not in owed]
            room = 0 if state.get("undelivered") else max(0, min(ISSUE_LINES, PENDING_MAX - len(lines) - 1))
            for w in owed[:room]:
                say(w["key"], w["text"])
            held = len(owed) - room
            if held > 0 and state.get("undelivered"):
                quiet.append(f"{held} issue line(s) wait for the undelivered reports")
            elif held > 0:
                lines.append(f"{held} more untriaged issue{'s' if held > 1 else ''} wait for the next pass.")
    except RuntimeError as ex:
        say("issues:read", f"could not read the open issues: {ex}")

    # Forget what no open PR carries, so the file does not grow — but only on a
    # pass that read the PRs, since an unread list is not an empty one. Issue
    # keys likewise, only on a pass that read the whole issue list.
    if untriaged is not None or malformed:
        state["fired"] = {k: v for k, v in state["fired"].items()
                          if not (k == "issues:page" or (k == "issues:node" and not malformed)
                                  or (untriaged is not None and k.startswith("issue:") and int(k[len("issue:"):]) not in untriaged))}
    if prs_ok:
        live = {pr["headRefOid"] for pr in prs}
        state["fired"] = {k: v for k, v in state["fired"].items()
                          if k.startswith(("issue:", "issues:"))
                          or (k.startswith("sweep:") and os.path.exists(k[len("sweep:"):]))
                          or k.endswith(":read") or k.rsplit(":", 1)[-1] in live}
        state["rerun"] = {k: v for k, v in state["rerun"].items() if k.rsplit(":", 1)[-1] in live}
    state["publish"] = {k: v for k, v in state["publish"].items()
                        if (t := parse_time(v.get("at"))) and now - t < PUBLISH_KEEP}

    if verbose:
        for q in quiet:
            print(q, file=sys.stderr)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--state", default="~/.local/state/topo-janitor/state.json")
    ap.add_argument("--checkout", default=CHECKOUT)
    ap.add_argument("--publish-timeout", type=float, default=45 * 60, metavar="SECONDS",
                    help="how long publish-topo.sh may run before it is killed and recorded as no answer")
    a = ap.parse_args(argv)
    now = datetime.now(timezone.utc)
    path = os.path.expanduser(a.state)
    if not a.dry_run:   # a dry run writes nothing: no directory, no lock, no state
        os.makedirs(os.path.dirname(path), exist_ok=True)
        lock = open(path + ".lock", "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("another pass holds the lock; exiting", file=sys.stderr)
            return 0
    state = load_state(path)
    sh = Shell(dry=a.dry_run, publish_timeout=a.publish_timeout)

    def persist():
        if not a.dry_run:
            save_state(path, state)

    def terminated(signum, frame):
        # launchctl bootout and a reboot send SIGTERM; raising here runs the
        # finally below (and subprocess.run kills the child it was waiting on).
        raise SystemExit(f"terminated by signal {signum}")

    signal.signal(signal.SIGTERM, terminated)
    try:
        try:
            run_pass(sh, state, now, os.path.expanduser(a.checkout), persist, verbose=a.verbose)
        except (Exception, SystemExit) as ex:  # noqa: BLE001 — the pass ends here, and what it did is still reported
            state.setdefault("pending", []).append(f"the pass stopped early: {type(ex).__name__}: {str(ex)[:200]}")
        deliver(sh, state, now, dry=a.dry_run)
    finally:
        persist()
    return 0


if __name__ == "__main__":
    sys.exit(main())
