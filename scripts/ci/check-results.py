"""Check actual jobs and WPF shards against the plan for this workflow run."""
import json
import os
import subprocess
import sys
import time

JOBS = {"macos": "mac", "windows-engine": "windows_engine", "windows-build": "windows_desktop",
        "windows-tests": "windows_desktop", "windows-arm64": "windows_arm64", "windows-installer": "installer"}


def check(plan, needs, jobs):
    if not plan.get("tree") or not plan.get("commit") or not plan.get("head"):
        raise ValueError("Missing the tested commit or tree")
    if plan["draft"] and (plan["jobs"] or plan["shards"]):
        raise ValueError("Unexpected platform work in the draft plan")
    required = {"changes", "contract"} | {name for name, flag in JOBS.items() if flag in plan["jobs"]}
    if set(needs) != {"changes", "contract", *JOBS}:
        raise ValueError("Incomplete job results")
    for name, job in needs.items():
        expected = "success" if name in required else "skipped"
        if job["result"] != expected:
            raise ValueError(f"{name}: expected {expected}, got {job['result']}")
    shards = ["Windows tests (" + row["shard"] + ")" for row in plan["shards"]]
    if bool(shards) != ("windows-tests" in required) or len(shards) != len(set(shards)):
        raise ValueError("Invalid Windows shard plan")
    # A failed-only rerun inherits passed jobs. Prefer the latest attempt for each name.
    latest = {job["name"]: job for job in sorted(jobs, key=lambda job: job["run_attempt"])}
    actual = {name for name, job in latest.items() if name.startswith("Windows tests (") and job["conclusion"] != "skipped"}
    if actual != set(shards):
        raise ValueError(f"Windows shards: expected {shards}, found {sorted(actual)}")
    def step(job, name, enabled=True):
        status = {s["name"]: s["conclusion"] for s in latest.get(job, {}).get("steps", [])}.get(name)
        expected = "success" if enabled else "skipped"
        if status != expected:
            raise ValueError(f"{job} / {name}: expected {expected}, got {status}")
    if "macos" in required:
        step("macOS (arm64)", "Build the Mac app and smoke-test its reporter", "mac_bundle" in plan["jobs"])
    for index, name in enumerate(shards):
        if latest[name]["conclusion"] != "success":
            raise ValueError(f"{name}: {latest[name]['conclusion']}")
        step(name, "Functional presentation tests")
        integration = name == "Windows tests (connections)" and "windows_integration" in plan["jobs"]
        step(name, "Desktop integration tests", integration)
        step(name, "Claude runtime without user Python", integration)
        step(name, "Engine idle and shutdown protocol", index == 0)


def main():
    plan = json.loads(os.environ["PLAN"])
    needs = json.loads(os.environ["NEEDS"])
    endpoint = f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}/jobs?filter=all&per_page=100"
    for delay in (0, 2, 5, 10):
        time.sleep(delay)
        pages = json.loads(subprocess.check_output(["gh", "api", "--paginate", "--slurp", endpoint]))
        try:
            check(plan, needs, [job for page in pages for job in page["jobs"]])
            break
        except ValueError as error:
            if delay == 10 or any(job["result"] in ("failure", "cancelled") for job in needs.values()):
                sys.exit(str(error))
    line = f"Verified {plan['commit']} (tree {plan['tree']}) with {len(plan['shards'])} Windows presentation shards."
    print(line)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
        print(line, file=handle)


if __name__ == "__main__":
    main()
