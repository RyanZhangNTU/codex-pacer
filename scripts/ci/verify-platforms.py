"""Record the tested checkout and require that exact tree before a release."""
import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile


WORKFLOW = ".github/workflows/platforms.yml"
CHECK = "Platforms verified"
RECEIPT = "platforms-tree.json"
MAX_ARTIFACT = 64 * 1024
REPOSITORY = "RyanZhangNTU/codex-pacer"


class GitHubError(RuntimeError):
    def __init__(self, endpoint, status):
        self.status = status
        super().__init__(f"GitHub API request failed for {endpoint}" + (f" (HTTP {status})" if status else ""))


def git(*arguments):
    return subprocess.check_output(["git", *arguments], text=True).strip()


def require_jobs(needs):
    def check(job, expected):
        if needs[job]["result"] != expected:
            raise ValueError(f"{job} must be {expected}, got {needs[job]['result']}")

    check("changes", "success")
    check("contract", "success")
    flags = needs["changes"]["outputs"]
    if any(flags.get(name) not in ("true", "false") for name in ("mac", "windows", "installer")):
        raise ValueError("Changed platforms did not report all platform flags")
    if flags["installer"] == "true" and flags["windows"] != "true":
        raise ValueError("Installer validation requires a Windows build")
    for platform, jobs in {
        "mac": ("macos",),
        "windows": ("windows-engine", "windows-build", "windows-tests", "windows-arm64"),
        "installer": ("windows-installer",),
    }.items():
        for job in jobs:
            check(job, "success" if flags[platform] == "true" else "skipped")


def record(path):
    require_jobs(json.loads(os.environ["PLATFORMS_NEEDS"]))
    commit = git("rev-parse", "HEAD")
    if commit != os.environ["GITHUB_SHA"]:
        raise ValueError("The Platforms checkout does not match the workflow revision")
    tree = git("rev-parse", "HEAD^{tree}")
    path.write_text(json.dumps({
        "run": int(os.environ["GITHUB_RUN_ID"]),
        "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "event": os.environ["GITHUB_EVENT_NAME"],
        "base": os.environ.get("GITHUB_BASE_REF", ""),
        "ref": os.environ["GITHUB_REF"],
        "commit": commit,
        "tree": tree,
    }) + "\n", encoding="utf-8")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"tree={tree}\n")


def read_receipt(data):
    if len(data) > MAX_ARTIFACT:
        raise ValueError("Platforms receipt archive is too large")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if archive.namelist() != [RECEIPT] or archive.getinfo(RECEIPT).file_size > 1024:
            raise ValueError("Unexpected Platforms receipt archive")
        result = json.loads(archive.read(RECEIPT))
    if not isinstance(result, dict):
        raise ValueError("Invalid Platforms receipt")
    return result


def github(endpoint, *flags):
    response = subprocess.run(["gh", "api", *flags, endpoint], capture_output=True, timeout=120)
    if response.returncode:
        match = re.search(rb"\(HTTP (\d{3})\)", response.stderr)
        raise GitHubError(endpoint, int(match[1]) if match else None)
    return response.stdout


def get(api, endpoint):
    return json.loads(api(endpoint))


def pages(api, endpoint, key):
    for page in json.loads(api(endpoint, "--paginate", "--slurp")):
        yield from page[key]


def candidate(api, repo, repository_id, artifact, tree):
    if artifact["expired"] or not 0 < artifact["size_in_bytes"] <= MAX_ARTIFACT:
        return None
    metadata = artifact.get("workflow_run")
    if not metadata or metadata["repository_id"] != repository_id:
        return None
    run_id = int(metadata["id"])
    run = get(api, f"{repo}/actions/runs/{run_id}")
    if (run["path"] != WORKFLOW or run["repository"]["id"] != repository_id
            or run["status"] != "completed" or run["conclusion"] != "success"):
        return None
    event = run["event"]
    if event != "pull_request" and (event != "workflow_dispatch" or run["head_branch"] != "develop"):
        return None
    # Bind the receipt to an authoritative run revision too. A PR whose head
    # differs from its tested merge tree needs a manual run on develop.
    head = run["head_sha"]
    if head != metadata["head_sha"] or not re.fullmatch(r"[0-9a-f]{40}", head):
        return None
    if get(api, f"{repo}/git/commits/{head}")["tree"]["sha"] != tree:
        return None
    attempt = int(run["run_attempt"])
    receipt = read_receipt(api(f"{repo}/actions/artifacts/{int(artifact['id'])}/zip"))
    if (receipt.get("run") != run_id or receipt.get("attempt") != attempt
            or receipt.get("event") != event or receipt.get("tree") != tree):
        return None
    commit = receipt.get("commit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        return None
    if event == "pull_request" and (receipt.get("base") != "develop"
                                    or not re.fullmatch(r"refs/pull/[0-9]+/merge", receipt.get("ref", ""))):
        return None
    if event == "workflow_dispatch" and (commit != head or receipt.get("ref") != "refs/heads/develop"):
        return None
    if get(api, f"{repo}/git/commits/{commit}")["tree"]["sha"] != tree:
        return None
    endpoint = f"{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100"
    checks = [job for job in pages(api, endpoint, "jobs") if job["name"] == CHECK]
    if len(checks) != 1 or checks[0]["status"] != "completed" or checks[0]["conclusion"] != "success":
        return None
    return run_id


def require_tree(api, repo, repository_id, tree):
    artifacts = f"{repo}/actions/artifacts?name=platforms-tree-{tree}&per_page=100"
    for artifact in pages(api, artifacts, "artifacts"):
        try:
            run = candidate(api, repo, repository_id, artifact, tree)
        except GitHubError as error:
            # Old PR merge objects and expired artifacts can disappear.
            # Authentication, network and other API errors fail the gate.
            if error.status not in (404, 410):
                raise
            continue
        except (KeyError, TypeError, ValueError, zipfile.BadZipFile):
            continue
        if run is not None:
            return run
    raise ValueError("No successful Platforms run verified the release tree. Run Platforms on develop before tagging.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", type=Path, metavar="RECEIPT")
    args = parser.parse_args()
    if args.record:
        record(args.record)
        return
    tree = git("rev-parse", "HEAD^{tree}")
    repository = os.environ.get("GITHUB_REPOSITORY", REPOSITORY)
    repo = "repos/" + repository
    repository_id = os.environ.get("GITHUB_REPOSITORY_ID")
    run = require_tree(github, repo, int(repository_id) if repository_id else get(github, repo)["id"], tree)
    print(f"Platforms verified release tree {tree}: https://github.com/{repository}/actions/runs/{run}")


if __name__ == "__main__":
    main()
