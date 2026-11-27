# Roadmap branch

This orphan branch holds the roadmap image at the top of the pinned issue [#299](https://github.com/RyanZhangNTU/codex-pacer/issues/299). It is never merged into other branches.

| File | Role |
|---|---|
| `roadmap.json` | The source: items, their stage and group, latest release, last-updated date |
| `render_roadmap.py` | Turns the JSON into the two images (Python 3, standard library only) |
| `roadmap-light.svg`, `roadmap-dark.svg` | The images the issue loads from `https://raw.githubusercontent.com/RyanZhangNTU/codex-pacer/roadmap/<file>` |

## Update the image

1. Check out this branch (`git worktree add <dir> roadmap`, or a separate clone).
2. Edit `roadmap.json`:
   - `updated`: today's date, `YYYY-MM-DD`.
   - `release`: the latest public version.
   - Each item: `title` (Chinese, about 20 characters at most), `en` (English, about 50 characters at most), `refs` (issue or PR numbers like `"#293"`, or `[]`), `stage` from 1 to 5 = 计划 Plan, 设计 Design, 开发 Build, 测试 Test, 发布 Ship.
   - Groups: `ship` (下个版本, merged and waiting for a release, stage 5), `progress` (正在做), `next` (接下来). The header counts come from the number of items in each group.
3. Run `python3 render_roadmap.py roadmap.json .` and open both SVGs in a browser to check that nothing overlaps or is cut off.
4. Commit the JSON and both SVGs together and push.

The issue shows the new image within about five minutes.

## When to update

- Work starts, changes stage, or merges into `develop`. A merged item goes to `ship` with stage 5.
- After a public release: remove the items that shipped and set `release`.
- When the owner adds or drops plans.

## What goes in

Only notable, user-facing work, described in plain words about what users get.
