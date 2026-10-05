# Git local changes — 0.15.0 / build 32

Date: 2026-10-05. This extends the [initial Git comparison validation](git-comparison-0.15.0.md) with staging-area and working-tree sources. Work stayed in `CrossDiff-main`; tests used generated repositories and isolated application sessions.

## Behavior

New local sessions open **All Uncommitted**: HEAD → working tree. **Staged** compares HEAD → index, and **Unstaged** compares index → working tree. Either side can independently select a commit, the index or the working tree. Earlier sessions retain their committed revisions; an unborn HEAD has an explicit empty baseline. Remote caches and bare repositories retain commit-only comparison.

The index preview reads the staged blob, even when the same path has subsequently changed on disk. Working-tree previews verify captured file identity and contents before publishing; changed files require Refresh. Viewing does not modify the source index, objects, branch or files. Untracked files are optional and ignore rules apply. Local source kinds and opaque snapshot identities are bound into the validated plugin response instead of masquerading as commits.

## Completed verification

- **107 offline Git core checks** passed, including stage-then-edit, staged additions/deletions, intent-to-add, untracked/ignored files, empty HEAD, sparse checkout, file modes, SHA-256 repositories, exact renames, submodule pointers, stale data, cancellation, resource budgets, nonblocking special-file rejection and symlink traversal protection. A separate executed check confirmed merge-base metadata labels the actual ancestor.
- **112 plugin checks** passed using the real restricted helper, including local snapshot metadata, empty baselines, wrong source kinds, stale/forged identities, complete row coverage and legacy committed input compatibility.
- Existing `scripts/check.sh` passed. The edition/plugin inventory's **10 checks** passed.
- **39 native Git workflow assertions passed** on the final frozen source. They exercise default creation, HEAD/index/working-tree byte separation, both read-only editors, find, source swapping, untracked inclusion, state restoration, old-state decoding, external edits and refresh, an unborn repository, unchanged source index/working files, and retained commit comparisons.
- Inspected actual paired-detail windows in Chinese/light, English/dark and the 860-point minimum width. Native source labels distinguish worktree/index from commit hashes; common presets explain their comparison direction.
- Full and Base **0.15.0 / build 32** were rebuilt and passed `codesign --verify --deep --strict`. Both contain the same Git 0.1.0 package. The actual bundled-helper check passed against both editions, including architecture and inventory integrity.
- Publication source/app audit, documentation links and patch formatting passed. No global dependencies were installed and no remote release was published by these checks.

## Boundaries

Local previews remain read-only. Unresolved index merge stages produce an explicit error rather than guessing a conflict version. Working bytes do not run clean/smudge or line-ending conversion; repositories using those transforms may show raw byte differences. Submodules retain the index pointer without inspecting nested dirty states. Local-source rename detection requires unambiguous identical contents.

Working capture limits: 50,000 candidates, 256 MiB per file, 1 GiB total and a 60-second scan; detail limits remain 2 MiB per side. Unsupported files or exceeded budgets fail explicitly. This round did not repeat remote authentication tests or validate Intel macOS; the initial Git record distinguishes the earlier real HTTPS test from untested private SSH servers.

Run `scripts/tests/check-git-core.sh`, `scripts/tests/check-git-plugin.sh` and `scripts/tests/check-git-workflow.sh` to reproduce. Native suites must run serially. Logs and native captures remain in ignored project-local `.build*` directories.
