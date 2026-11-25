"""Checks the structure of .github/workflows/release.yml. Needs PyYAML.

Runs its own good and bad fixtures first, so that a checker that flags nothing fails.
Usage: python tests/support/test_release_workflow.py
"""

import copy
import pathlib
import re
import sys

import yaml

WORKFLOW = pathlib.Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
CHECKOUT = "actions/checkout"
RELEASE = "softprops/action-gh-release"
PINS = {CHECKOUT: "actions/checkout@v7", RELEASE: "softprops/action-gh-release@v3"}
HASH_SCRIPT = ".github/scripts/Test-ReleaseHash.ps1"
HASH_OUTPUT = "steps.hash.outputs.sha256_cmd"
# github.event carries the tag name too; github["ref"] and steps["id"] are the index form of the same names
REF = re.compile(r"""\bgithub\s*(?:\.\s*|\[\s*['"])(?:ref|ref_name|head_ref|event)\b""", re.I)
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.S)
OUTPUT = re.compile(r"""\bsteps\s*(?:\.\s*|\[\s*['"])([\w-]+)""", re.I)


def action(step):
    return str(step.get("uses", "")).split("@")[0]


def expressions(value):
    """Every ${{ }} body anywhere inside a parsed YAML value."""
    if isinstance(value, dict):
        return [e for v in value.values() for e in expressions(v)]
    if isinstance(value, list):
        return [e for v in value for e in expressions(v)]
    return EXPR.findall(value) if isinstance(value, str) else []


def is_tainted(expr, ids, env):
    return bool(
        REF.search(expr)
        or any(m in ids for m in OUTPUT.findall(expr))
        or any(re.search(r"\benv\s*(?:\.\s*|\[\s*['\"])%s\b" % re.escape(n), expr, re.I) for n in env)
    )


def check(doc):
    """Returns the list of violations in a parsed workflow."""
    bad = []
    jobs = doc.get("jobs") or {}

    # AC-31 action versions
    for name, count in ((CHECKOUT, 3), (RELEASE, 1)):
        uses = [s["uses"] for j in jobs.values() for s in j.get("steps", []) if action(s) == name]
        if len(uses) != count or any(u != PINS[name] for u in uses):
            bad.append("AC-31 %s: %s, expected %d x %s" % (name, uses, count, PINS[name]))

    # AC-32 permissions and credentials
    if doc.get("permissions") != {"contents": "read"}:
        bad.append("AC-32 top-level permissions: %s" % doc.get("permissions"))
    for name, job in jobs.items():
        expected = {"contents": "write"} if name == "release" else None
        perms = job.get("permissions")
        if perms != expected and not (name != "release" and perms == {"contents": "read"}):
            bad.append("AC-32 permissions of job %s: %s" % (name, perms))
    rwu = info = 0
    for step in (jobs.get("sync-launcher") or {}).get("steps", []):
        if action(step) != CHECKOUT:
            continue
        opts = step.get("with") or {}
        persist = opts.get("persist-credentials", True)
        if opts.get("repository", "matbanik/rwu") == "matbanik/info":
            info += 1
            if persist is not True:
                bad.append("AC-32 the matbanik/info checkout must keep its credentials")
        else:
            rwu += 1
            if persist is not False:
                bad.append("AC-32 a matbanik/rwu checkout in sync-launcher keeps its credentials")
    if (rwu, info) != (1, 1):
        bad.append("AC-32 sync-launcher checkouts: rwu %d, info %d" % (rwu, info))

    # AC-33 nothing derived from the ref name is pasted into a script
    for name, job in jobs.items():
        ids, env = set(), set()
        for scope in (doc, job):
            env |= {k for k, v in (scope.get("env") or {}).items() if any(is_tainted(e, ids, env) for e in expressions(v))}
        for step in job.get("steps", []):
            step_env = env | {k for k, v in (step.get("env") or {}).items() if any(is_tainted(e, ids, env) for e in expressions(v))}
            inline = [e.strip() for e in expressions(step.get("run", "")) if is_tainted(e, ids, step_env)]
            if inline:
                bad.append("AC-33 job %s, step %r: inline %s" % (name, step.get("name"), inline))
            if step.get("id") and (inline or step_env or any(is_tainted(e, ids, env) for e in expressions(step))):
                ids.add(step["id"])

    # AC-34 the hash check sits between the last write of the body and the release
    steps = (jobs.get("release") or {}).get("steps", [])
    checks = [i for i, s in enumerate(steps) if HASH_SCRIPT in str(s.get("run", ""))]
    writes = [i for i, s in enumerate(steps) if "release_body.md" in str(s.get("run", "")) and i not in checks]
    release = [i for i, s in enumerate(steps) if action(s) == RELEASE]
    if len(checks) != 1 or len(release) != 1 or not writes or not max(writes) < checks[0] < release[0]:
        bad.append("AC-34 order: body %s, hash check %s, release %s" % (writes, checks, release))
    else:
        step = steps[checks[0]]
        if step.get("shell") != "pwsh":
            bad.append("AC-34 shell of the hash check: %s" % step.get("shell"))
        if "if" in step or "continue-on-error" in step:
            bad.append("AC-34 the hash check can be skipped or ignored")
        # the expected hash may be inline or arrive through env
        sources = expressions(step.get("run", "")) + expressions(step.get("env"))
        if not any(HASH_OUTPUT in e for e in sources):
            bad.append("AC-34 the hash check does not get %s" % HASH_OUTPUT)
        for word in ("-BodyPath release_body.md", "-LauncherPath rwu.ps1", "-ExpectedHash"):
            if word not in step["run"]:
                bad.append("AC-34 the hash check lacks %s" % word)
    return bad


GOOD = yaml.safe_load(
    """
permissions: {contents: read}
jobs:
  release:
    permissions: {contents: write}
    steps:
      - uses: actions/checkout@v7
      - {name: version, id: version, env: {TAG: "${{ github.ref_name }}"}, run: 'echo "version=${TAG#v}" >> "$GITHUB_OUTPUT"'}
      - {name: verify, env: {TAG_VER: "${{ steps.version.outputs.version }}"}, run: 'echo "$TAG_VER"'}
      - {name: hash, id: hash, run: 'sha256sum Reset_WindowsUpdate.cmd'}
      - {name: body, run: 'echo "${{ steps.hash.outputs.sha256_cmd }}" > release_body.md'}
      - name: check
        shell: pwsh
        env: {HASH: "${{ steps.hash.outputs.sha256_cmd }}"}
        run: ./.github/scripts/Test-ReleaseHash.ps1 -BodyPath release_body.md -LauncherPath rwu.ps1 -ExpectedHash $env:HASH
      - uses: softprops/action-gh-release@v3
        with: {name: "RWU v${{ steps.version.outputs.version }}"}
  sync-launcher:
    steps:
      - uses: actions/checkout@v7
        with: {persist-credentials: false}
      - uses: actions/checkout@v7
        with: {repository: matbanik/info, token: x}
      - {name: push, env: {TAG: "${{ github.ref_name }}"}, run: 'git commit -m "$TAG"'}
"""
)


def step(doc, job, name_or_index):
    steps = doc["jobs"][job]["steps"]
    if isinstance(name_or_index, int):
        return steps[name_or_index]
    return next(s for s in steps if s.get("name") == name_or_index)


def swap(doc, job, i, j):
    steps = doc["jobs"][job]["steps"]
    steps[i], steps[j] = steps[j], steps[i]


BAD = [
    ("AC-31", "old checkout", lambda d: step(d, "release", 0).update(uses="actions/checkout@v4")),
    ("AC-31", "newer checkout", lambda d: step(d, "sync-launcher", 1).update(uses="actions/checkout@v8")),
    ("AC-31", "old release action", lambda d: step(d, "release", 6).update(uses="softprops/action-gh-release@v2")),
    ("AC-31", "missing checkout", lambda d: d["jobs"]["release"]["steps"].pop(0)),
    ("AC-32", "write at top level", lambda d: d.update(permissions={"contents": "write"})),
    ("AC-32", "no top-level permissions", lambda d: d.pop("permissions")),
    ("AC-32", "write-all", lambda d: d.update(permissions="write-all")),
    ("AC-32", "release without write", lambda d: d["jobs"]["release"].pop("permissions")),
    ("AC-32", "sync-launcher with write", lambda d: d["jobs"]["sync-launcher"].update(permissions={"contents": "write"})),
    ("AC-32", "rwu checkout keeps credentials", lambda d: step(d, "sync-launcher", 0).pop("with")),
    ("AC-32", "rwu checkout named explicitly", lambda d: step(d, "sync-launcher", 0).update({"with": {"repository": "matbanik/rwu"}})),
    ("AC-32", "info checkout without credentials", lambda d: step(d, "sync-launcher", 1)["with"].update({"persist-credentials": False})),
    ("AC-33", "inline ref_name", lambda d: step(d, "sync-launcher", "push").update(run='git commit -m "${{ github.ref_name }}"')),
    ("AC-33", "inline ref_name, index form", lambda d: step(d, "sync-launcher", "push").update(run="echo ${{ github['ref_name'] }}")),
    ("AC-33", "inline version output", lambda d: step(d, "release", "verify").update(run='V="${{ steps.version.outputs.version }}"')),
    ("AC-33", "inline env copy", lambda d: step(d, "release", "verify").update(run='V="${{ env.TAG_VER }}"')),
    ("AC-34", "no hash check", lambda d: d["jobs"]["release"]["steps"].pop(5)),
    ("AC-34", "hash check before body", lambda d: swap(d, "release", 4, 5)),
    ("AC-34", "hash check after release", lambda d: swap(d, "release", 5, 6)),
    ("AC-34", "body written again after hash check", lambda d: d["jobs"]["release"]["steps"].insert(6, {"run": "echo x >> release_body.md"})),
    ("AC-34", "wrong shell", lambda d: step(d, "release", "check").pop("shell")),
    ("AC-34", "ignored failure", lambda d: step(d, "release", "check").update({"continue-on-error": True})),
    ("AC-34", "wrong hash output", lambda d: step(d, "release", "check").update(env={"HASH": "${{ steps.hash.outputs.sha256_ps1 }}"})),
]


def main():
    failed = 0
    problems = check(GOOD)
    if problems:
        failed += 1
        print("FIXTURE FAIL good fixture flagged: %s" % problems)
    for ac, name, mutate in BAD:
        doc = copy.deepcopy(GOOD)
        mutate(doc)
        if not any(p.startswith(ac) for p in check(doc)):
            failed += 1
            print("FIXTURE FAIL %s %s: not flagged" % (ac, name))
    print("FIXTURES good=1 bad=%d failed=%d" % (len(BAD), failed))
    problems = check(yaml.safe_load(WORKFLOW.read_text(encoding="utf-8")))
    for p in problems:
        print("FAIL " + p)
    print("WORKFLOW violations=%d" % len(problems))
    return 1 if failed or problems else 0


if __name__ == "__main__":
    sys.exit(main())
