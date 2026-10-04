# 并行开发工作流 / Parallel development

本地工作区可以使用五个独立仓库：一个用于集成和完整测试，四个用于不同方向的开发。它们连接同一个 GitHub 仓库，但各自拥有完整源码、独立 `.git`、构建缓存和开发会话。这个目录布局只存在于本机；GitHub 仍然是一个项目，通过分支协作。

Use five independent clones of the same GitHub repository: one integration checkout and four development checkouts. Each has its own Git metadata, build output and local development data. GitHub continues to contain one project, organized by branches.

```text
CrossDiff/
├── CrossDiff-main/
├── CrossDiff-image/
├── CrossDiff-photo/
├── CrossDiff-office/
└── CrossDiff-video/
```

| 文件夹 / Directory | 分支 / Branch | 用途 / Purpose |
| --- | --- | --- |
| `CrossDiff-main` | `main` | 集成、完整测试与发布 / Integration, full validation and releases |
| `CrossDiff-image` | `zhangjy/image` | 图片对比 / Image comparison |
| `CrossDiff-photo` | `zhangjy/photo` | 摄影分析 / Photography analysis |
| `CrossDiff-office` | `zhangjy/office` | 办公文档 / Office documents |
| `CrossDiff-video` | `zhangjy/video` | 视频功能研发 / Video development |

每个目录的 `origin` 均通过 SSH 连接[同一个 GitHub 仓库](https://github.com/JunyangZhangUSTC/CrossDiff)，当前分支跟踪远端同名分支。视频目录是研发入口，并不表示视频插件已经实现。

All clones use an SSH origin for the same repository and track their matching remote branch. The video branch is a development workspace; it does not imply a shipped video plugin.

## 在功能目录开发 / Work in a feature checkout

在对应子目录打开编辑器或智能体项目。以图片分支为例，在新的 Bash 终端中从外层 `CrossDiff/` 运行：

Open the relevant child directory as your editor or agent project. For image work, start a fresh Bash terminal in the outer `CrossDiff/` directory:

```sh
cd CrossDiff-image
source scripts/project-env.sh
git status --short --branch
git pull --ff-only
```

完成修改后运行受影响的检查，检查并提交具体文件，然后推送。以下文件名需替换为实际改动：

Run the checks relevant to your change, review and stage the intended files, then push. Replace the example file paths below with your actual changes:

```sh
git diff --check
git diff
git add path/to/changed-file
git commit -m "feat: describe the change"
git push
```

不要跨目录修改另一个工作区。公共接口和共享文件的改动应先协调；分支隔离不会自动消除合并冲突。推送前若远端分支有新提交，先获取并合并，不强制覆盖。

Keep each task inside its own checkout. Coordinate changes to shared interfaces and files; independent clones do not prevent merge conflicts. Fetch and integrate remote changes before pushing instead of force-pushing over them.

## 在主目录合并与验收 / Integrate and validate in main

在新的 Bash 终端中，从外层目录进入主仓库。确保没有未提交修改，再逐个合并已经推送的功能分支：

In a fresh Bash terminal, enter the main checkout from the outer directory. Start with a clean working tree and merge one published feature branch at a time:

```sh
cd CrossDiff-main
source scripts/project-env.sh
git status --short --branch
git pull --ff-only
git fetch origin
git merge --no-ff origin/zhangjy/image
```

如有冲突，先解决、检查并完成合并提交，再开始下一个分支。替换最后一条命令中的分支名即可合并摄影、办公或视频方向。需要放弃尚未完成的冲突合并时，使用 `git merge --abort`。

Resolve conflicts, inspect the result and complete the merge before starting another branch. Substitute the photography, Office or video branch as needed. Use `git merge --abort` to cancel an unfinished conflicted merge.

合并完成后运行完整检查与应用构建，通过后再推送主分支：

After integrating the branches, run full validation and build the app before pushing main:

```sh
bash scripts/check-all.sh
bash scripts/tests/check-office-import.sh
bash scripts/tests/check-office-plugin.sh
bash scripts/tests/check-office-model.sh
bash scripts/tests/check-office-workflow.sh
bash scripts/build-app.sh
codesign --verify --deep --strict dist/CrossDiff.app
python3 scripts/audit-publication.py --app dist/CrossDiff.app
git push origin main
```

原生窗口检查需要登录的 macOS 图形会话，并且应在整台 Mac 上串行执行。构建可以并行，但多个工作区同时编译会争用内存与 CPU；可用 `CROSSDIFF_BUILD_JOBS` 限制 OpenCV 构建并行度。普通分支推送不等于发布 Release，正式版本沿用[发布流程](releasing.md)。

Native window checks require a logged-in macOS graphical session and must run serially across all checkouts on the same Mac. Parallel builds compete for memory and CPU; `CROSSDIFF_BUILD_JOBS` bounds OpenCV build parallelism. A branch push is not a Release; follow the [release guide](releasing.md).

## 将主分支更新带回功能分支 / Bring main back into a feature branch

在功能目录、工作区干净时运行。保留已发布分支历史，避免反复重写其他开发者已经获取的提交：

Run in a clean feature checkout to integrate main without rewriting published history:

```sh
git fetch origin
git merge origin/main
# Resolve conflicts and run the affected checks before pushing.
git push
```

## 本地数据与迁移 / Local data and relocation

- 外层目录只是容器。开发命令、构建和 Git 操作都在对应子目录中运行。
- 每个项目加载自己的 `scripts/project-env.sh`，缓存和会话分别写入自己的 `.build/`。换项目应开新终端；若必须复用已加载环境的终端，先 `unset CROSSDIFF_DATA_DIR`，再加载目标项目环境。
- 迁移旧仓库时，应先正常退出正在使用它的开发应用和构建进程。保留已有会话与本地文件；带旧绝对路径的 Swift/CMake 缓存需隔离后重新生成，不能直接复用。
- 测试使用项目内合成数据。通过 `bash scripts/open-dev-app.command` 启动对应开发包，以隔离不同工作区的会话。直接双击 `.app` 使用普通应用数据位置。
- 新克隆首次构建会准备自己的固定版本依赖；生成物和开发会话不提交 Git，也不从其他分支共享可写目录。

The outer directory is only a container. Run Git, builds and development tools inside a child checkout. Each checkout loads its own project environment and owns its `.build/` cache and sessions. Start a fresh terminal when switching projects, or unset `CROSSDIFF_DATA_DIR` before loading the target environment. Preserve local data when relocating a repository, but rebuild caches that contain old absolute paths. Launch through `scripts/open-dev-app.command` for isolated development sessions; opening the `.app` directly uses ordinary application data. Do not share writable build directories or commit generated files.
