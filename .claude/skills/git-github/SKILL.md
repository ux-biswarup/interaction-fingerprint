---
name: git-github
description: Git and GitHub workflow for this public research project: small milestone commits, what must never be committed, branch and PR conventions, and keeping experiment history reproducible. Use before committing, tagging, or publishing anything. Priority: now.
---
# Git / GitHub for a public research repo

## Commit in small milestones

Follow the sequence in the setup guide, section 10:

```text
chore: create iOS app
feat: add ARKit face tracking
feat: add gaze recording
feat: add facial signal recording
feat: add interaction event model
feat: add session export
```

Conventional prefixes: `feat`, `fix`, `chore`, `docs`, `research` (protocol or hypothesis
changes), `analysis` (notebooks and scripts), `data-schema` (schema version bumps).

## Never commit

participant recordings, raw camera or face video, session exports under `Data/`, API keys,
signing credentials (`*.p12`, `*.mobileprovision`), personal identifiers, `xcuserdata/`.
The `.gitignore` already covers these. Check `git status` before every commit and run
`git diff --cached --stat` to confirm no `Data/` paths slipped in.

If something sensitive is committed: do not just delete it in a new commit. Rewrite history with
`git filter-repo`, force-push, and treat any key as compromised.

## Reproducible experiments

- Tag the app build used for each study run: `git tag study-v0-pilot-2026-09-20`.
- Every export records `appVersion` and the git short SHA (inject via a build setting or a
  generated `BuildInfo.swift`). Analysis notebooks print the SHA they analyze.
- Keep `Research/` (protocols, hypotheses, findings) in the same repo so the history shows what
  was believed when.

## Branches and PRs

Commit and push straight to `main`. No feature branches, no pull requests. This is the
user's stated preference for this repo, decided on 2026-09-05: it is a solo project, so a
pull request is a review step with no reviewer.

- `main` must always build. Run the tests before pushing, not after.
- Put the lab notebook detail in the commit message body instead of a PR description.
  State the hypothesis the commit serves, and what was verified.
- Revisit this only if the user says they want a different approach.

## Xcode-specific hygiene

- Commit `Package.resolved` so dependency versions are pinned.
- The project uses buildable folders, so new files do not touch `project.pbxproj`. If the pbxproj
  changes unexpectedly, inspect the diff before committing.

## Related
`experimental-thinking`, `privacy-responsible-ai`.
