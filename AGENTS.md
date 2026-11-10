# Working on DiskMap

DiskMap is a disk-usage treemap for macOS: a C scanner and renderer with a
Swift/AppKit window on top. This file is for coding agents and anyone else
making changes. The user-facing description is in `README.md`.

## Layout

    Sources/CScan/      C core. scan.c (getattrlistbulk thread pool, hard-link and
                        clone accounting), layout.c (squarified treemap, cushion
                        renderer), include/CScan.h (the whole public API)
    Sources/dmscan/     command-line front end to the scanner
    Sources/DiskMap/    the AppKit app; no nibs or storyboards, UI is built in code
    Tests/CScanTests/   scanner and layout tests against real files in a temp folder
    scripts/            icon, demo data and screenshot generators
    build-app.sh        assembles and signs DiskMap.app
    install.sh          the curl installer published in the README
    version.txt         current version; written by the release pipeline

## Commands

    swift build -c release                      # build everything
    swift test                                  # run the tests
    ./build-app.sh                              # DiskMap.app for this Mac
    ./build-app.sh --universal                  # Apple silicon + Intel, as released
    .build/release/dmscan ~ --depth 2           # scan from the terminal

Check a UI change by looking at it, not only by compiling it:

    .build/release/DiskMap /Applications --snapshot /tmp/window.png   # scan, save a picture of the window, quit
    .build/release/DiskMap --snapshot /tmp/welcome.png                # the welcome screen
    DISKMAP_SNAPSHOT_SUMMARY=1 .build/release/DiskMap /Applications --snapshot /tmp/summary.png
    .build/release/DiskMap ~ --render /tmp/map.png --size 1400x900    # the map alone, no window

`scripts/make-screenshot.sh` regenerates `docs/screenshot.png` from made-up
data. Never put a screenshot of real files in the repository.

## Rules of the house

- **No dependencies.** Swift, C and the system frameworks only.
- **macOS 15 or later.** The deployment target is set in `Package.swift`,
  `build-app.sh` (Info.plist) and `install.sh`; change all three together.
- **Speed is the feature.** The scanner does about 300,000 items a second.
  Measure before and after any change to `scan.c` with
  `dmscan /System/Volumes/Data` and put both numbers in the pull request.
  In particular, every attribute added to the `getattrlistbulk` request costs
  time on every file: `ATTR_CMNEXT_CLONEID` is free, `ATTR_CMNEXT_PRIVATESIZE`
  and `ATTR_CMNEXT_EXT_FLAGS` make the scan two to three times slower, which is
  why clones are resolved after the scan instead.
- **Sizes are space on disk, counted once.** Hard links and APFS clones must
  not be double counted. A change to the accounting needs a test in
  `Tests/CScanTests`.
- **Nothing is deleted without the user confirming it.** The only destructive
  action in the app is Move to Trash, behind an alert.
- **Do not edit `version.txt` or `CHANGELOG.md` by hand.** The release
  pipeline writes both.
- Text shown to users is plain and specific: say what happened and what to do.

## Commits and pull requests

Release notes are generated from commit messages, so they are written for the
people who use the app.

Every commit on `main` follows [Conventional Commits](https://www.conventionalcommits.org):

    <type>(<optional scope>): <summary>

    <optional body: what changed and why, wrapped at 72 columns>

| Type | Use it for | In the release notes | Version bump |
|---|---|---|---|
| `feat` | something a user can now do | Features | minor |
| `fix` | something that was wrong for a user | Bug Fixes | patch |
| `perf` | same behaviour, faster or lighter | Performance | patch |
| `refactor`, `docs`, `test`, `build`, `ci`, `chore` | everything else | hidden | none |

- The summary is imperative, lower case, without a full stop, and describes
  the effect for the user: `fix(scanner): count files on external drives once`,
  not `fix: update scan.c`.
- Scopes in use: `scanner`, `map`, `app`, `cli`, `install`, `release`.
- A breaking change gets `!` after the type (`feat!: ...`) and a
  `BREAKING CHANGE:` paragraph in the body saying what to do about it.
- One logical change per commit. A fix and an unrelated refactor are two
  commits, or two pull requests.

Pull requests:

- Branch from `main`; name the branch `type/short-description`
  (`fix/clone-accounting`).
- **The pull request title is a Conventional Commit summary.** Pull requests
  are squash-merged with the title as the commit message, so the title is the
  line that appears in the release notes. The `PR title` check enforces the
  format.
- The description says what changed, why, and how it was checked (tests run,
  scan timings, a snapshot for UI changes).
- `swift test` and `./build-app.sh` must pass; CI runs both.
- Do not merge the pull request titled `chore(main): release X.Y.Z` unless
  asked to cut a release.

## What GitHub enforces

- **`main` takes changes only through pull requests.** Direct pushes, force
  pushes and deleting the branch are rejected, for the owner too. A pull
  request needs the `Build and test` and `Conventional commit title` checks
  to pass and its review conversations resolved, and is squash-merged.
- **Release tags (`v*`) cannot be moved or deleted.** A bad release is fixed
  by releasing the next version, not by retagging.
- **Workflow actions are pinned to a commit**, with the version in a comment
  (`uses: actions/checkout@<sha> # v4.4.0`). Only actions published by GitHub
  and `googleapis/release-please-action` are allowed to run; Dependabot
  proposes updates once a week. Do not add another action without asking.
- The owner can merge a pull request whose checks have not passed
  (`gh pr merge --squash --admin`, or the bypass box on the page). This exists
  for the release pull request: it is opened by a bot, so its checks wait for
  someone to press "Approve and run". Do not use it for anything else.
- Report security problems as described in `SECURITY.md`, not in an issue.

## Releases

Releases are cut by [release-please](https://github.com/googleapis/release-please)
(`.github/workflows/release.yml`):

1. Every push to `main` updates a pull request named
   `chore(main): release X.Y.Z`. It contains the next version in `version.txt`
   and the new section of `CHANGELOG.md`, built from the `feat`, `fix` and
   `perf` commits since the last release.
2. Merging that pull request tags `vX.Y.Z` and publishes the GitHub release
   with those notes.
3. The same workflow then builds the universal app, zips it and attaches
   `DiskMap.zip` and `DiskMap.zip.sha256` to the release. `install.sh`
   downloads those two files from the latest release.

While the version is below 1.0, a `feat` bumps the minor version and a
breaking change does too. To force a specific version, add a `Release-As: 1.0.0`
footer to a commit on `main`.

The app is not notarized: there is no Developer ID. Release builds are signed
ad hoc, which is why the README installs with `curl` (no quarantine flag) and
why Full Disk Access has to be granted again after an update.
