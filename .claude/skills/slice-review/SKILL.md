---
name: slice-review
description: Answers the per-change review questions against the branch diff, with evidence, and produces the Slice review section for the PR body. Run after make format, lint, build and the tests are green, and before gh pr create, on any branch whose PR will be feat, fix or perf.
when_to_use: Use when the user says "slice review", "run the review questions", "ready for the PR", "push and raise the PR" on a feat, fix or perf branch, or when you are about to run gh pr create for such a branch. Do not use to review a single file or someone else's PR, and not on docs or chore branches.
allowed-tools: [Read, Grep, Glob, Bash]
argument-hint: [base-branch]
---

# Slice review

The per-change gate for feat, fix and perf PRs. It runs after the gates in
`CLAUDE.md` are green and before `gh pr create`. Nothing here is answered by
prediction: every answer comes from the finished diff, with evidence.

## Process

1. Base branch is `$0` when given, otherwise `main`. Review
   `git diff <base>...HEAD` plus anything staged or unstaged. Read each changed
   file in full, not only the hunks.
2. Answer the seven questions in the output block below, in writing. Each
   answer cites its evidence (a `file:line`, or a command and its output) or
   says "not relevant to this change" and why. If an answer needs a
   measurement, take it.
3. List every behaviour that is now different: first from the user's point of
   view, then from the perspective of other modules. Do not list files.
4. State whether the large-library scenario was run (the app against a
   full-size library, not a fixture), and if not, why.
5. For each finding outside this slice, propose a GitHub issue to the user:
   a title and a two-line body. File it with `gh issue create` only when the
   user says yes, then link it in the block.
6. Produce the output block. It becomes the `## Slice review` section of the
   PR body via `gh pr create --body-file`. The form in
   `.github/PULL_REQUEST_TEMPLATE.md` is the same block for PRs opened by
   hand; keep the two in step.

## Output

Exactly this block, every `Answer:` filled:

```markdown
## Slice review

1. What observers, timers, or views will re-run as a result, and how often?
   Answer:
2. What is the complexity in terms of library size?
   Answer:
3. What did you create that needs cancelling or invalidating, and who owns it?
   Answer:
4. Which error paths propagate, recover, or fail loudly?
   Answer:
5. What existing type or utility did you check before adding a new one?
   Answer:
6. What did you stub, simplify, or leave incomplete?
   Answer:
7. What is the strongest argument that this is the wrong approach?
   Answer:

**What a user, or another module, would notice is different** (behaviour, not files):
-

**Tried against a full-size library** (thousands of tracks, not a test fixture): yes / no, because

**Things noticed but not fixed here**: issue links, or none.
```

## Hard rules

- No answer without evidence, or an explicit "not relevant" with a reason.
- Do not soften a finding to keep the PR small. Propose the issue and move on.
- Only feat, fix and perf PRs. Other types are exempt from the gate.
