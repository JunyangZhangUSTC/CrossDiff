# Git comparison: repository snapshots and isolation

Updated: 2026-10-05. Scope: the built-in Git comparison plugin, backed by the system Git executable. These notes distinguish Git's documented behavior from CrossDiff implementation choices.

## Why use Git plumbing

Comparison now accepts committed snapshots, the staging area and the working tree. Git owns object decoding, pack files, revision resolution, index enumeration, rename detection and merge-base semantics. CrossDiff uses those facilities instead of implementing a second Git parser. Working-file fingerprints use Apple CryptoKit and the repository’s Git blob object format, without writing objects.

- `rev-parse --verify --end-of-options <revision>^{commit}` verifies one commit. CrossDiff resolves both inputs once, then passes only immutable full object IDs to subsequent commands. Moving branches cannot combine two different snapshots during a comparison. Revision flags, ranges, reflog expressions and path expressions are not accepted as input. [Git rev-parse](https://git-scm.com/docs/git-rev-parse)
- `ls-tree --full-tree -r -l -z` returns object mode, type, ID, size and raw NUL-terminated path names. CrossDiff builds the complete file union from these two trees, so “all files” and “changes only” use the same result. Byte-based path identity preserves distinct NFC/NFD names. Invalid UTF-8 names produce an explicit error instead of an incomplete tree. [Git ls-tree](https://git-scm.com/docs/git-ls-tree)
- `diff-tree --raw -r -z --find-renames=<threshold>% --no-ext-diff --no-textconv` supplies rename pairs. Rename detection is a similarity heuristic; disabling it shows deletions and additions. CrossDiff caps exhaustive rename candidates with `-l1000`, so very large sets can be shown as additions/deletions rather than exhausting CPU. Modes and object IDs still identify all file changes. [Git diff-tree](https://git-scm.com/docs/git-diff-tree)
- `cat-file blob <object-ID>` reads stored bytes directly. CrossDiff never requests `--filters` or `--textconv`: `.gitattributes`, LFS smudge commands and user-defined converters do not run. LFS pointer files remain pointers. Symlinks display their stored target text; submodules display their commit pointer without fetching or opening nested repositories. [Git cat-file](https://git-scm.com/docs/git-cat-file)

## Comparison choices

The default for a new local session is HEAD versus the working tree; existing commit sessions keep their selected revisions. Other pairs use the complete left snapshot versus the complete right snapshot. Optional merge-base mode compares their common ancestor against the right snapshot. CrossDiff uses `merge-base --all` and requires exactly one result; unrelated histories or multiple best ancestors need an explicit commit selection instead of an arbitrary guess. [Git merge-base](https://git-scm.com/docs/git-merge-base)

The narrow file tree displays unchanged, added, deleted, modified, renamed and type-changed files. A permission-only change remains visible even when blob bytes are identical. The file preview reuses the existing text diff model; unsupported encodings and binary bytes receive a hexadecimal preview. Preview text preserves UTF-8, BOM-marked UTF-16, original newlines and Unicode sequences.

## Local repositories

CrossDiff runs `/usr/bin/git` as a fixed executable with structured arguments. It checks for an actual installed Apple Git implementation before launching the system stub, avoiding an automatic developer-tools installation prompt. Apple Command Line Tools or Xcode is therefore required in this first implementation; Git is not bundled.

Local operations do not check out branches, stage files, write configuration, fetch objects, update submodules or modify the index. `GIT_OPTIONAL_LOCKS=0` disables optional locking and `GIT_NO_REPLACE_OBJECTS=1` prevents replacement refs from changing the meaning of an object ID. Git's environment/configuration controls are documented in [Git](https://git-scm.com/docs/git) and [Git config](https://git-scm.com/docs/git-config).

CrossDiff additionally blocks all transport protocols during local reads and sets `GIT_NO_LAZY_FETCH=1`. Missing objects in a partial/shallow repository must be completed by the user; reading a local comparison cannot silently download them. System/global Git configuration is disabled for subprocesses, and explicit command configuration disables hooks, fsmonitor, automatic maintenance, external diff, interactive prompts and custom credential helpers. This is process hardening, not a security sandbox for a compromised Git binary or arbitrary repository contents.

## Remote repositories

The user can explicitly download an HTTPS or SSH repository into an application-owned **bare** cache, then explicitly refresh it. No working tree is created and no checkout filters or submodules execute. Git documents bare clone as a repository without a checked-out worktree. [Git clone](https://git-scm.com/docs/git-clone)

GitHub/Gitee repository-page URLs and GitLab subgroup URLs normalize to clone addresses. Self-hosted HTTPS and SSH clone addresses, including SCP-style SSH addresses and explicit SSH ports, are accepted. Plain HTTP, local/file transports, custom helper protocols, embedded passwords/tokens, query strings, fragments and web file/branch pages are rejected. The application does not infer access tokens or rewrite global Git settings.

Authentication is intentionally bounded:

- HTTPS supports public repositories without configured credential helpers. For a private HTTPS repository, clone it with the user's normal tools and open the local directory.
- SSH can use an existing agent or default key and an already trusted host. CrossDiff disables arbitrary SSH configuration, proxy/local commands and interactive prompts, never accepts a new host key automatically, and does not alter `known_hosts`.

A cache marker records the normalized remote and format version. Reopening verifies that marker and bare-repository state, rejects symbolic-link cache locations, and does not promote an ordinary local repository into a writable cache. Refresh uses `fetch --atomic` with explicit branch/tag refspecs; updates target only that cache. The user repository is never a fetch destination. Git's atomic fetch updates all requested refs together or none. [Git fetch](https://git-scm.com/docs/git-fetch)

## Limits and cancellation

These are CrossDiff implementation limits, not Git format limits:

| Operation | Boundary |
| --- | --- |
| Directory enumeration / working capture | Streamed records / chunked hashing; no fixed file count, byte total, per-file size or total scan deadline; cancellable |
| Other local subprocesses | Bounded command output and a 45-second deadline; cancellation while draining stdout and stderr |
| Restricted Git plugin | Bounded batches of complete file pairs; helper budgets apply per batch, not to the repository |
| Core blob read | Maximum 20 MiB; the interface can request a smaller preview budget |
| Remote clone/refresh | 300-second deadline; sampled 2 GiB cache and 200,000 filesystem-entry limit |
| Failed initial download | Temporary clone removed; an existing destination is never overwritten |

Directory commands drain NUL-delimited records without keeping a second complete stdout buffer. Individual records remain bounded to reject malformed output. Working content is hashed in 1 MiB chunks; removing the old scan caps does not allocate a whole large file. Working scans report bytes read and files scanned, while the UI throttles progress delivery and rejects stale callbacks.

The plugin bridge uses at most 128 complete file pairs per helper call, keeping both sides of a rename together. It first checks global source coverage, then validates source identities, paths, classifications and coverage for every response. Only after all batches succeed does it publish the aggregate result. The general restricted-helper input/output/memory/time budgets are unchanged and apply to each batch. A failed or cancelled batch cannot publish earlier batches as a successful comparison. Directory metadata and final rows still scale with file count, so this is removal of fixed product ceilings, not a promise of constant memory or arbitrary hardware capacity.

Remote downloads include complete Git history and can be significantly larger than the current files. The sampled disk limit can overshoot briefly while Git is writing; it is a stop condition, not a quota reservation. Cancelling a refresh preserves atomic refs, although Git may leave downloaded objects in the cache. Large clone optimization, private HTTPS credential integration, patch application and write-back are future work.

## Verification

`bash scripts/tests/check-git-core.sh` builds isolated fixtures inside this checkout and covers actual branches/tags, rename detection, executable bits, binary and empty blobs, tabs/newlines/Unicode paths, NFC/NFD identity, symlink/submodule behavior, merge bases, dirty working-tree preservation, helper suppression, URL/revision validation and process limits.

`CROSSDIFF_GIT_NETWORK_CHECK=1 bash scripts/tests/check-git-core.sh` additionally exercises a small public HTTPS clone, cache reopen, atomic refresh, mismatched-remote rejection and destination preservation. This opt-in check requires network access; the default regression suite stays offline.

## Staged and unstaged changes

Git distinguishes HEAD → index (staged changes), index → working tree (unstaged changes), and HEAD → working tree (all changes since a commit). CrossDiff names these **Staged**, **Unstaged** and **All Uncommitted**, and also permits either source on either side. An unborn HEAD can act as an empty baseline. These meanings follow [Git diff](https://git-scm.com/docs/git-diff). CrossDiff's optional inclusion of untracked files extends the ordinary tracked-file diff view.

The host reads stage-0 entries using NUL-delimited `ls-files` metadata, rejects unresolved higher stages, and excludes intent-to-add placeholders from the index snapshot. Untracked paths come from `ls-files --others --exclude-standard`; this respects available ignore files without loading global Git configuration. Missing skip-worktree paths retain index contents. See [Git ls-files](https://git-scm.com/docs/git-ls-files).

Working files are opened through directory file descriptors with no symlink-ancestor traversal. The capture records node identity, mode, size, timestamps and the raw Git blob digest; preview reads verify them again. Content changes require Refresh, never mixing a captured tree with a later file. Index blobs remain immutable even if the user stages a newer version later. No temporary index, tree or blob is written to the source repository.

These choices are deliberately explicit:

- Filemode follows the repository's `core.filemode`; staged contents come from the actual index.
- Working bytes do not run clean/smudge, LFS or newline conversion. Such repositories may show raw on-disk differences. Submodules retain index pointers without inspecting nested changes.
- Comparisons containing a local source use only unambiguous exact-content rename pairs, rather than implying a partial-content similarity estimate. Merge-base requires two committed revisions.
- Capture has no fixed per-file size, aggregate bytes, file-count or total-time ceiling. Directory metadata remains in memory, while file contents are hashed in chunks. Cancellation and special-file errors stop the operation without publishing incomplete results. Detail remains independently limited to 2 MiB per side.
- Source kind and snapshot identity are explicitly included in the restricted plugin contract and validated in its response. Neither the index nor the working tree is represented as a fictitious commit.
