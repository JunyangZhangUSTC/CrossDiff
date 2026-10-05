# Git comparison — 0.15.0

Date: 2026-10-05. Scope: source 0.15.0 / build 31, Git plugin 0.1.0, Apple Silicon macOS with Apple Command Line Tools. Work, generated repositories, downloads, test sessions and screenshots stayed inside `CrossDiff-main`. No sibling development checkout or user repository was modified.

## Implemented behavior

Base and Full bundle the real restricted Git plugin. New → Git opens one local working/bare/worktree repository or an explicitly requested HTTPS/SSH remote. Branches, tags and commit IDs resolve to immutable commit snapshots. A narrow directory tree supports changed/all files and path search; the paired read-only detail reuses native text diff, aligned lines, find and difference navigation. Rename and merge-base options are available. Binary data has a labeled bounded Hex preview; symlinks and submodules show committed records only.

The native host owns Git subprocesses and object reads. The restricted plugin sees tree metadata and host-validated rename evidence, never credentials, absolute paths, Git commands or blob contents. Local reads do not alter the working tree, index or branch. Remote repositories use an application-owned bare cache; opening/restoring an existing cache is offline, and fetch requires Refresh.

## Completed checks

| Check | Result and evidence |
| --- | --- |
| `scripts/check.sh` | PASS: existing core regression suite, including backward-compatible session decoding. |
| `CROSSDIFF_GIT_NETWORK_CHECK=1 bash scripts/tests/check-git-core.sh` | PASS: 74 checks (67 offline, 7 real HTTPS/cache checks). Actual public clone, reopen and refresh used a small GitHub repository. URL/parser coverage also includes GitLab, Gitee and self-hosted clone addresses. |
| `scripts/tests/check-git-plugin.sh` | PASS: 61 checks of the packaged JavaScript algorithm and strict host contract. |
| Plugin inventory / Release unit checks | PASS: 10 inventory and 34 release safeguards; Base includes Archive/Git, Full includes all eight official plugins. |
| Plugin protocol / Archive checks | PASS: 43 generic protocol and 52 Archive checks after adding the new input/view contract. |
| `scripts/tests/check-workflow.sh` | PASS: existing full native text workflow, editing, menus, search/replace, undo and localization. |
| `scripts/tests/check-new-comparison-workflow.sh` | PASS: 123 native assertions covering the existing chooser, typed inputs, plugin handoff, pairing, source preservation and translated sheets. |
| `scripts/tests/check-official-plugin-ui.sh` | PASS: Git appears in the Base inventory and supports removal/offline restoration; plugin management tested in both languages, light/dark and minimum width. |

Native checks ran serially with independent session directories. The first Git-window run exposed an unactivated test-window focus precondition; activating the check window before invoking native menu commands fixed the harness, after which the real find action passed. The shipping menu remains focus-scoped. Inspection also corrected the source Picker's cached translated titles and made returning to a completed tree resume a cancelled file preview.

Final-source verification also passed:

- `scripts/tests/check-git-workflow.sh`: **27 assertions**, including cancelled-preview recovery, read-only find routing, local/remote source switching, invalid revisions, missing-cache restoration without network access and unchanged dirty working files.
- Inspected the actual source sheet in Chinese/light and English/dark; inspected paired details in Chinese/light, English/dark and the 860-point minimum window. Text, highlights, trees and controls remain visible.
- Rebuilt **Full and Base 0.15.0 / build 31**. `codesign --verify --deep --strict` succeeded for both.
- `scripts/tests/check-bundled-helpers.sh` passed against both actual bundles: four matching-architecture executables, real archive fixtures, catalog/package integrity and unchanged source data. Base has Archive/Git, Full has eight plugins.
- The standalone `dist/Plugins/Git.crossdiffplugin` matches each app's bundled Git package byte for byte.
- Publication audit passed on source and the Full app; `git diff --check` passed. CI definitions and the aggregate check runner include the Git checks, but no remote CI run is claimed.

Ignored `.build-git-workflow/renders/` holds source-page and paired-detail captures; these are real application windows, not HTML mockups. Reproducible test and artifact locations are documented in the development guide.

## Boundaries / not verified

- SSH private-host authentication was covered by policy and argument checks, not an end-to-end connection to a private server. GitLab/Gitee/self-hosted URL normalization does not claim an authenticated server test.
- Private HTTPS credential helpers, SSH custom-config aliases/proxies, HTTP transports, working-tree/index comparison, write-back and conflict resolution are outside this implementation. Private HTTPS repositories can be cloned externally and compared locally.
- System Git is required; CrossDiff does not bundle or automatically install developer tools.
- Remote retrieval includes full history, with cancellation, a five-minute deadline and sampled soft disk/entry limits. Extremely large repositories and Intel macOS were not validated here.
- No new GitHub tag, Release, or remote CI result is implied by this local validation. Build signatures are ad-hoc, not Developer ID notarization.
