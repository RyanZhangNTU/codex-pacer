# Roadmap branch

This orphan branch holds only the roadmap image shown at the top of the pinned issue [#299](https://github.com/RyanZhangNTU/codex-pacer/issues/299). It is never merged into `develop` or `main`, and nothing else lives here.

| File | Role |
|---|---|
| `roadmap.json` | The source: items, their stage and group, latest release, last-updated date |
| `render_roadmap.py` | Turns the JSON into the two images (Python 3, standard library only) |
| `roadmap-light.svg`, `roadmap-dark.svg` | The images the issue loads from `https://raw.githubusercontent.com/RyanZhangNTU/codex-pacer/roadmap/<file>`. Never rename them. |

## Update the image

1. Check out this branch on its own (a separate clone or `git worktree add <dir> roadmap`), never inside a code branch.
2. Edit `roadmap.json`:
   - `updated`: today's date, `YYYY-MM-DD`.
   - `release`: the latest public version.
   - Each item: `title` (Chinese, about 20 characters at most), `en` (English, about 50 characters at most), `refs` (issue or PR numbers like `"#293"`, or `[]`), `stage` from 1 to 5 = 计划 Plan, 设计 Design, 开发 Build, 测试 Test, 发布 Ship.
   - Groups: `ship` (下个版本, merged and waiting for a release, stage 5), `progress` (正在做), `next` (接下来). The header counts come from the number of items in each group.
3. Run `python3 render_roadmap.py roadmap.json .` and open both SVGs in a browser. Check that no title runs into its `#` numbers and nothing is cut off.
4. Commit the JSON and both SVGs together and push normally (`git push origin roadmap`, never `--force`).

The issue shows the new image within about five minutes. Its body does not change, so nobody is notified.

## When to update

- Work starts, changes stage, or a PR merges into `develop`: move the item and set its stage. A merged item goes to `ship` with stage 5.
- After a public release: remove the items that shipped, set `release`, and add the release to the **最近发布 · Recently shipped** table in the issue body (keep the latest three).
- The owner adds or drops plans: change the items as asked.

## Edit the issue body

Only the release table and the text around the image live in the body. Read the current body first (`gh issue view 299 --json body --jq .body > body.md`), edit that file, check it is not empty (`test -s body.md`), then run `gh issue edit 299 --body-file body.md`. An empty body file wipes the issue.

## What the owner wants in the roadmap

- Only notable, user-facing work. Leave out small settings and toggles, internal or performance work, and items the owner has not agreed to.
- Plain wording about what users get, no implementation details, no version labels like "Pacer 5.0", no dates.
- The body invites people to comment in this issue. Don't add subscribe prompts, 👍 voting or a text version of the table.
- Never put these files on the `badges` branch: its workflow force-pushes it with only `downloads.json`.
