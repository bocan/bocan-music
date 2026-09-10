<!-- The PR title must be a Conventional Commit, type(scope): subject.
     It becomes the squash commit subject on main. -->

Closes #

## Summary

What changed and why, in a few sentences. Developer detail is generated from
the commit subjects at release time; the listener-facing note goes in
CHANGELOG.md under Unreleased (feat, fix and perf PRs).

## Slice review

Every feature, fix or performance change answers the same seven questions
before it merges, whether a person or a coding assistant wrote it. They are
the questions a careful reviewer would ask anyway; answering them up front
means the reviewer reads answers instead of guessing. Short answers are fine.
"Not relevant to this change, because ..." is a valid answer. Point at a file
and line, or a command and its output, where you can.

<!-- Delete this section on docs, chore and other PRs. Keep the questions in
     step with .claude/skills/slice-review/SKILL.md, which produces this same
     block for assistant-written PRs. -->

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

## Notes for reviewers

Setup steps, screenshots, known limitations. Delete if empty.
