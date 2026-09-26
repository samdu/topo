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
     and that automerge has left unmerged for `grace` minutes, pinned to the
     head the green run was read for;
  2. reruns the failed jobs of a red validate run once per head when the red
     is a suite job (`test`) or the reviewer never ran (`reviewer_ran`), the
     run has been over for `settle` minutes and no run is in progress; a run
     red again after that is reported with its failing jobs and tests;
  3. republishes the over-the-air install page when the commit it carries is
     not origin/main's;
  4. removes a linked worktree whose branch's PR merged more than `sweep`
     hours ago, killing first any tmux session sitting in it;
  5. reports, once per condition per head every `repeat` minutes: a verdict
     that blocks, a draft untouched for `grace`, a green PR with Proof boxes
     unticked, a ready PR with no validate run, a run cancelled with nothing
     after it, and a PR nothing has touched for `idle` minutes while no run
     is in progress.

Everything it decides is a function of what it read; everything it does is a
`gh`, `git`, `tmux` or shell call behind `Shell`, so `--dry-run` prints the
pass instead. The report, when there is one, goes into buddy-prime through
the mesh socket its bridge registers on this host, as one message from
`topo-janitor`; an undeliverable report is kept in the state file and sent
with the next. A quiet pass sends nothing. Nothing here reads a review,
merges over a red or missing verdict, or edits code.

State: ~/.local/state/topo-janitor/state.json (override with --state).
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone

REPO = "samdu/topo"
WORKFLOW = "pr-validate.yaml"
INSTALL_PAGE = "https://experiments.hexagon.zone/ota/files/623f17f9f38db5b81d0b/version.json"
PUBLISH = "~/github/experiments/ota/publish-topo.sh"
CHECKOUT = "~/github/topo"
REG_DIR = os.path.expanduser("~/.claude/sessions")
REPORT_TO = "buddy-prime"
FROM = "topo-janitor"

GRACE = timedelta(minutes=15)      # automerge's chance, a draft's, a box's
SETTLE = timedelta(minutes=10)     # a red run is left this long before a rerun
IDLE = timedelta(minutes=45)       # nothing moving, nothing running
REPEAT = timedelta(minutes=180)    # a standing condition is said again after this
SWEEP = timedelta(hours=24)        # a merged branch's worktree lives this long
PUBLISH_RETRY = timedelta(hours=2)  # a failed publish is tried again after this
PENDING_MAX = 60                   # report lines kept for a later delivery

UNCHECKED = re.compile(r"^\s*[-*] \[ \]", re.M)   # automerge.yaml's own test
SUITE_JOBS = ("test",)
NO_VERDICT_JOBS = ("reviewer_ran",)


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


def decide_pr(pr, run, jobs, state, now, require_label=False):
    """What one open PR wants from this pass.

    Returns a list of dicts: {"kind": merge|rerun|report, "key": ..., "text": ...}.
    `run` is the newest pull_request validate run for the PR's head, or None;
    `jobs` its jobs as [{name, conclusion, id}]. Pure: nothing is read or done.
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

    red = [j for j in jobs if j.get("conclusion") == "failure"]
    red_names = [j["name"] for j in red]
    suite_red = [j for j in red if j["name"] in SUITE_JOBS]
    no_verdict = any(j["name"] in NO_VERDICT_JOBS for j in red) and not suite_red
    rerun_key = f"{n}:{head}"
    if suite_red or no_verdict:
        why = "the reviewer never ran (no verdict)" if no_verdict else f"a suite job is red ({', '.join(j['name'] for j in suite_red)})"
        if rerun_key not in state.get("rerun", {}):
            if since > SETTLE:
                out.append({"kind": "rerun", "key": rerun_key, "run_id": run["id"], "number": n,
                            "text": f"reran the failed jobs of {title} (run {run['id']}): {why}."})
            return out
        detail = ", ".join(red_names) or conclusion
        report("red", f"{title}: red again on {short} after one rerun ({detail}); {why}.")
        return out

    if "review_gate" in red_names:
        report("verdict", f"{title}: the reviewer blocked {short}; the verdict is on the PR.")
    if age > IDLE:
        detail = ", ".join(red_names) or conclusion
        report("idle", f"{title}: nothing has moved for {minutes(age)}; validate is {conclusion} ({detail}).")
    return out


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


def decide_sweep(worktrees, checkout, merged_at, now):
    """Worktrees to remove: linked, on a branch, whose PR merged over SWEEP ago.

    `merged_at(branch)` answers the merge time of the branch's PR, or None.
    """
    out = []
    for wt in worktrees:
        if os.path.realpath(wt["path"]) == os.path.realpath(checkout) or not wt.get("branch"):
            continue
        m = merged_at(wt["branch"])
        if not m or now - m["mergedAt"] < SWEEP:
            continue
        out.append({"path": wt["path"], "branch": wt["branch"], "number": m["number"],
                    "age": now - m["mergedAt"]})
    return out


def due(state, key, now):
    """A report key is due when it has not fired inside REPEAT."""
    last = parse_time(state.get("fired", {}).get(key))
    return last is None or now - last >= REPEAT


# --- the shell -------------------------------------------------------------

class Shell:
    """Every process the janitor runs. `dry` runs nothing that changes anything."""

    def __init__(self, dry=False, log=None):
        self.dry = dry
        self.log = log or (lambda s: print(s, file=sys.stderr, flush=True))

    def run(self, argv, timeout=120, check=True, mutating=False, **kw):
        if mutating and self.dry:
            self.log(f"dry-run: {shlex.join(argv)}")
            return subprocess.CompletedProcess(argv, 0, "", "")
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, **kw)
        if check and p.returncode != 0:
            raise RuntimeError(f"{shlex.join(argv[:3])}… exited {p.returncode}: {p.stderr.strip()[-400:]}")
        return p

    def gh_json(self, *args):
        return json.loads(self.run(["gh", *args]).stdout or "null")

    def gh_api(self, path, jq=None):
        args = ["api", path]
        if jq:
            args += ["--jq", jq]
        return self.gh_json(*args)

    def open_prs(self):
        return self.gh_json("pr", "list", "--repo", REPO, "--state", "open", "--limit", "50", "--json",
                            "number,title,isDraft,headRefName,headRefOid,updatedAt,body,baseRefName,labels")

    def require_label(self):
        """automerge.yaml's label rule: True, False, or None when it cannot be read
        (a variable that is not set reads as an error too, and means False)."""
        p = self.run(["gh", "variable", "get", "AUTOMERGE_REQUIRE_LABEL", "--repo", REPO], check=False)
        if p.returncode == 0:
            return p.stdout.strip() == "true"
        if "variable not found" in (p.stderr or "").lower() or "not found" in (p.stderr or "").lower():
            return False
        return None

    def newest_run(self, head):
        runs = self.gh_api(f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?head_sha={head}&event=pull_request&per_page=100",
                           "[.workflow_runs[] | {id, status, conclusion, created_at, updated_at}]") or []
        runs.sort(key=lambda r: (r["created_at"], r["id"]))
        return runs[-1] if runs else None

    def jobs(self, run_id):
        return self.gh_api(f"repos/{REPO}/actions/runs/{run_id}/jobs?per_page=100",
                           "[.jobs[] | {id, name, conclusion}]") or []

    def job_log(self, job_id):
        p = self.run(["gh", "api", f"repos/{REPO}/actions/jobs/{job_id}/logs"], timeout=120, check=False)
        return p.stdout or ""

    def merge(self, number, head):
        self.run(["gh", "pr", "merge", str(number), "--repo", REPO, "--squash", "--delete-branch",
                  "--match-head-commit", head], mutating=True)

    def rerun(self, run_id):
        self.run(["gh", "run", "rerun", str(run_id), "--repo", REPO, "--failed"], mutating=True)

    def main_sha(self):
        return self.run(["gh", "api", f"repos/{REPO}/commits/main", "--jq", ".sha"]).stdout.strip()

    def published_commit(self):
        p = self.run(["curl", "-sS", "-m", "20", INSTALL_PAGE], check=False)
        try:
            return json.loads(p.stdout).get("commit")
        except (ValueError, AttributeError):
            return None

    def publish(self):
        script = os.path.expanduser(PUBLISH)
        p = self.run(["bash", script, "origin/main"], timeout=45 * 60, check=False, mutating=True)
        return p.returncode == 0, (p.stdout + p.stderr)

    def worktrees(self, checkout):
        return parse_worktrees(self.run(["git", "-C", checkout, "worktree", "list", "--porcelain"]).stdout)

    def merged_pr(self, branch):
        rows = self.gh_json("pr", "list", "--repo", REPO, "--state", "merged", "--head", branch,
                            "--limit", "1", "--json", "number,mergedAt") or []
        if not rows:
            return None
        return {"number": rows[0]["number"], "mergedAt": parse_time(rows[0]["mergedAt"])}

    def tmux_sessions(self):
        p = self.run(["tmux", "list-sessions", "-F", "#{session_name}\t#{pane_current_path}"], check=False)
        return [tuple(l.split("\t", 1)) for l in p.stdout.splitlines() if "\t" in l]

    def kill_tmux(self, name):
        self.run(["tmux", "kill-session", "-t", name], mutating=True)

    def remove_worktree(self, checkout, path, branch):
        self.run(["git", "-C", checkout, "worktree", "remove", path], mutating=True)
        self.run(["git", "-C", checkout, "branch", "-D", branch], mutating=True, check=False)


# --- the report ------------------------------------------------------------

def find_session(name):
    """The live registration named `name`, newest first; None when there is none."""
    regs = []
    for path in glob.glob(os.path.join(REG_DIR, "*.json")):
        try:
            with open(path) as f:
                reg = json.load(f)
            os.kill(int(reg.get("pid")), 0)
        except (OSError, ValueError, TypeError):
            continue
        if reg.get("name") == name and reg.get("messagingSocketPath"):
            regs.append(reg)
    regs.sort(key=lambda r: r.get("updatedAt") or 0, reverse=True)
    return regs[0] if regs else None


def send_to_session(reg, text):
    """One mesh envelope into the session's socket, with its inbox token when it
    publishes one. Raises OSError when the socket will not take it."""
    sock = reg["messagingSocketPath"]
    auth = b""
    digest = hashlib.sha256(sock.encode()).hexdigest()
    for key in glob.glob(os.path.join(REG_DIR, f"*.{digest}.key")):
        try:
            with open(key) as f:
                token = json.load(f).get("peerToken")
        except (OSError, ValueError):
            continue
        if token:
            auth = (json.dumps({"type": "auth", "token": token}) + "\n").encode()
            break
    origin = f"uds:/nonexistent/{FROM}.sock"
    content = (f'<cross-session-message from="{origin}" from-name="{FROM}">\n{text}\n'
               "</cross-session-message>")
    env = {"msgV": 1, "msg_id": str(uuid.uuid4()), "type": "user",
           "message": {"role": "user", "content": content}, "priority": "next", "from": origin}
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(sock)
        s.sendall(auth + (json.dumps(env) + "\n").encode())
    finally:
        s.close()


def deliver(lines, state, now, dry=False, log=print, warn=None):
    warn = warn or (lambda s: print(s, file=sys.stderr, flush=True))
    pending = state.get("pending", [])
    lines = (pending + lines)[-PENDING_MAX:]
    if not lines:
        return
    text = f"[{FROM}] pass at {now.strftime('%Y-%m-%dT%H:%MZ')}\n" + "\n".join(f"- {l}" for l in lines)
    if dry:
        log(text)
        return
    reg = find_session(REPORT_TO)
    try:
        if not reg:
            raise OSError(f"no live session named {REPORT_TO} on this host")
        send_to_session(reg, text)
        state["pending"] = []
    except OSError as ex:
        warn(f"report not delivered ({ex}); kept for the next pass")
        state["pending"] = lines


# --- one pass --------------------------------------------------------------

def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def run_pass(sh, state, now, checkout, verbose=False):
    lines = []
    quiet = []
    state.setdefault("fired", {})
    state.setdefault("rerun", {})
    state.setdefault("publish", {})

    # 1, 2, 5: the open PRs.
    try:
        prs = sh.open_prs()
        require_label = sh.require_label()
    except RuntimeError as ex:
        lines.append(f"could not read the open PRs: {ex}")
        prs, require_label = [], False
    for pr in prs:
        try:
            run = jobs = None
            if not pr["isDraft"]:
                run = sh.newest_run(pr["headRefOid"])
                jobs = sh.jobs(run["id"]) if run and run["status"] == "completed" else []
            wants = decide_pr(pr, run, jobs or [], state, now, require_label)
        except RuntimeError as ex:
            lines.append(f"#{pr['number']}: could not read its runs: {ex}")
            if "rate limit" in str(ex).lower():
                lines.append("GitHub is rate limiting; the rest of the PRs wait for the next pass.")
                break
            continue
        if not wants:
            quiet.append(f"#{pr['number']}: nothing to do")
        for w in wants:
            if w["kind"] == "merge":
                try:
                    sh.merge(w["number"], w["head"])
                    lines.append(w["text"])
                except RuntimeError as ex:
                    lines.append(f"#{w['number']}: merge refused: {ex}")
            elif w["kind"] == "rerun":
                try:
                    sh.rerun(w["run_id"])
                    state["rerun"][w["key"]] = {"run": w["run_id"], "at": now.isoformat()}
                    lines.append(w["text"])
                except RuntimeError as ex:
                    lines.append(f"#{w['number']}: rerun refused: {ex}")
            elif due(state, w["key"], now):
                text = w["text"]
                if ":red:" in w["key"]:
                    names = []
                    for j in jobs or []:
                        if j.get("conclusion") == "failure" and j["name"] in ("topo_unit", "topo_ui", "others"):
                            names += failing_tests(sh.job_log(j["id"]))
                    if names:
                        text += " Failing: " + "; ".join(dict.fromkeys(names)) + "."
                lines.append(text)
                state["fired"][w["key"]] = now.isoformat()
            else:
                quiet.append(f"{w['key']}: said within the last {minutes(REPEAT)}")

    # 3: the install page.
    try:
        main_sha = sh.main_sha()
        published = sh.published_commit()
        why = decide_publish(published, main_sha, state, now)
        if why:
            ok, log = sh.publish()
            state["publish"][main_sha] = {"at": now.isoformat(), "ok": ok}
            if ok:
                lines.append(f"republished the install page at {main_sha[:7]}: {why}.")
            else:
                tail = " | ".join(l.strip() for l in log.strip().splitlines()[-6:])
                lines.append(f"republishing the install page at {main_sha[:7]} failed ({why}): {tail}")
        else:
            quiet.append(f"install page: at {published}, main is {(main_sha or '')[:7]}")
    except RuntimeError as ex:
        lines.append(f"could not check the install page: {ex}")

    # 4: worktrees of merged branches.
    try:
        merged = {}

        def merged_at(branch):
            if branch not in merged:
                merged[branch] = sh.merged_pr(branch)
            return merged[branch]

        for wt in decide_sweep(sh.worktrees(checkout), checkout, merged_at, now):
            killed = []
            for name, cwd in sh.tmux_sessions():
                if cwd == wt["path"] or cwd.startswith(wt["path"].rstrip("/") + "/"):
                    sh.kill_tmux(name)
                    killed.append(name)
            try:
                sh.remove_worktree(checkout, wt["path"], wt["branch"])
                tm = f"; killed tmux {', '.join(killed)}" if killed else ""
                lines.append(f"swept worktree {os.path.basename(wt['path'])} ({wt['branch']}, #{wt['number']} merged {minutes(wt['age'])} ago){tm}.")
            except RuntimeError as ex:
                key = f"sweep:{wt['path']}"
                if due(state, key, now):
                    lines.append(f"worktree {os.path.basename(wt['path'])} ({wt['branch']}, #{wt['number']} merged) will not remove: {ex}")
                    state["fired"][key] = now.isoformat()
    except RuntimeError as ex:
        lines.append(f"could not read the worktrees: {ex}")

    # Forget fired keys for heads that no longer exist, so the file does not grow.
    live = {pr["headRefOid"] for pr in prs}
    state["fired"] = {k: v for k, v in state["fired"].items()
                      if k.startswith("sweep:") or k.rsplit(":", 1)[-1] in live}
    state["rerun"] = {k: v for k, v in state["rerun"].items() if k.rsplit(":", 1)[-1] in live}

    if verbose:
        for q in quiet:
            print(q, file=sys.stderr)
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--state", default="~/.local/state/topo-janitor/state.json")
    ap.add_argument("--checkout", default=CHECKOUT)
    a = ap.parse_args(argv)
    now = datetime.now(timezone.utc)
    path = os.path.expanduser(a.state)
    state = load_state(path)
    sh = Shell(dry=a.dry_run)
    lines = run_pass(sh, state, now, os.path.expanduser(a.checkout), verbose=a.verbose)
    deliver(lines, state, now, dry=a.dry_run)
    if not a.dry_run:
        save_state(path, state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
