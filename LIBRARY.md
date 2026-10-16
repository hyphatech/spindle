# A Hypha Stack library

<!-- Kept word for word across Hypha Stack's libraries. A copy is never edited in place: it is rewritten from the one original. -->

How a change to a library reaches its users, the same in every library of
Hypha Stack. What is the library's own -- its packages, what else of it is
behaviour -- is in its `AGENTS.md`, beside the line that imports this.

## Changes

- A user-visible change adds a line under `## Unreleased` in
  `CHANGES.md`, in the same commit. A breaking one says so.
- A change that makes a sentence in a document false edits that sentence in
  the same commit.
- A user-visible change updates the `.mli` it touches, and the document
  its users read for it: the README, for a new supported feature or a
  removed limitation, unless the library's `AGENTS.md` names another.

## Releases

[Semantic Versioning 2.0.0](https://semver.org). Before 1.0, a breaking
change bumps the minor version and anything else the patch; from 1.0, a
breaking change waits for the next major version, an addition bumps the
minor and a fix the patch. A library's packages are released together, at
one version.

Breaking means code that follows these rules may stop compiling or behave
differently: removing or renaming anything in an `.mli`, changing a type,
adding a required argument, or changing a default or documented behaviour.
Adding a function, a module, an optional argument or a constructor to a
public variant is not breaking: a variant grows in a minor version, so a
match on one that must compile across versions ends in a catch-all arm. A
variant the library's `AGENTS.md` names closed is the exception. Nor is the
wording of an error or a log line breaking, while what the library's
`AGENTS.md` names as behaviour is.

The version lives only in the git tag (`0.1.0`, no `v`). A release renames
`## Unreleased` in `CHANGES.md` to the version and date, and tags it. The
GitHub release notes are that entry with each paragraph and bullet on one
line, since GitHub keeps every line break in release notes. A release is
pushed first and tagged only once CI is green on the commit the tag names:
a broken build is never tagged.

Publishing the GitHub release runs `.github/workflows/release.yml`, which
uploads the source archive to it and publishes the release to Hypha's
opam repository, `hyphatech/opam-repository`, where users install it from
once that repository's CI has installed it. A published version never
changes; running the workflow by hand with a tag publishes a release
that missed it.
