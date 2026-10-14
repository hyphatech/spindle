# Git

<!-- Managed copy: kept word for word across Hypha's repositories. Do not edit it here; it is overwritten. -->

How work becomes a commit on `main`, the same in every Hypha repository.

## Commits

- **One piece of work is one commit on `main`**, whatever it took to make:
  a branch is squashed as it lands, so `main` reads as a list of changes,
  each whole. A commit holds its tests, its documents and, where the
  repository keeps a `CHANGES.md`, its line there.
- **The subject is an imperative sentence**, capitalised, under 72
  characters, with no full stop: `Keep a session across restarts`. It
  says what the change does for a reader of the log, never which files it
  touched.
- **The body says why**, wrapped at 72: the problem or the decision, and
  what was weighed against it. Never what the diff already shows, a test
  count or a file list. A fix too small to need a reason has a subject
  alone.
- **No trailers**: no `Co-Authored-By`, no `Signed-off-by`, no "Generated
  with". Who wrote a line is not why it changed.

## Where work happens

- **A piece of work gets a worktree; a fix does not.** Work -- anything
  that changes what the code does, touches more than one file, or needs a
  check run before it lands -- starts in a worktree made from the local
  `main` before its first edit, under `.hypha/worktrees/`. A fix -- a
  typo, a wording slip, a value the owner named exactly -- goes on `main`
  and is committed at once, so `main` never holds uncommitted work. A fix
  that grows moves to a worktree before its next edit. When unsure, it is
  work.
- **Work lands locally.** Its branch is squashed to one commit, rebased
  onto the local `main` and fast-forwarded into it, and the worktree and
  branch are removed. Nothing is fetched or pushed to land it.
- **Finishing work sends nothing anywhere.** An agent never pushes and
  never opens a pull request unless the owner asks for one in so many
  words; done is a commit in its worktree, waiting for the owner to land
  it. `main` reaches GitHub when its owner pushes it.
- **A pull request is the exception**, for when one is asked for. Its
  branch is named for its subject (`keep-a-session-across-restarts`), it
  holds everything the branch holds, and it is squash-merged once its
  checks pass, its subject the title and ` (#<number>)` -- never a merge
  commit. When it merges is the owner's decision.

## A pull request's body

```markdown
## Why

<The commit's body, unwrapped: the problem or the decision.>

## Changes

- <What behaves differently, one to five lines. Not a file list.>

## Verified

- <Anything run by hand, and what was tried.>

## Docs

<The document changed and the sentence it no longer says, or "None: no sentence became false.">
```

Each paragraph and bullet is one line, because GitHub renders every
newline as a break. No author trailer, no footer, no checkboxes.
