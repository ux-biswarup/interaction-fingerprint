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

- `main` is always buildable. Work on short-lived branches: `feat/gaze-projection`,
  `analysis/dwell-baseline`.
- Open a PR even when solo; the description is the lab notebook entry. Link the hypothesis.
- Use `gh pr create` and `gh pr view` from the terminal.

## Xcode-specific hygiene

- Commit `Package.resolved` so dependency versions are pinned.
- The project uses buildable folders, so new files do not touch `project.pbxproj`. If the pbxproj
  changes unexpectedly, inspect the diff before committing.

## Related
`experimental-thinking`, `privacy-responsible-ai`.
