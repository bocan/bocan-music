# Maintainability Audit -- Findings Ledger

The durable record of the audit. **Every cluster considered gets a row**, in all
four outcomes, so nothing is silently dropped and no future audit re-litigates a
decision already made. Append as you go; never delete a row.

Read the method and the decision rubric in [README.md](README.md) first.

## How to fill this in

- **ID**: `S<session>-<n>`, e.g. `S1-3` for the third cluster considered in
  Session 1.
- **Location(s)**: `file:line` for each copy, or a directory + pattern if many.
- **Kind**: from the taxonomy (near-duplicate-fn, copy-paste-block,
  parallel-types, boilerplate-wrapper, repeated-literal, test-scaffolding).
- **Copies / lines**: how many copies and roughly how many lines each, plus the
  normalized-diff overlap if measured (e.g. "3x ~12 lines, 90% identical").
- **Decision**: `consolidated` | `tolerated` | `rejected` | `deferred`.
- **Rationale**: one line. For `consolidated`, name the new shared symbol and the
  before/after line delta. For `rejected`, name which rubric step killed it
  (break-even, coupling, config-bag, test-churn). For `deferred`, name the target
  (Session 10 / cross-module).
- **Commit**: short hash, for `consolidated` rows.

## Shared surface (grows bottom-up)

As each session confirms or creates a reusable helper, list it here so higher
sessions dedup against it instead of re-copying. Format: `symbol -- module -- what it does`.

| Symbol | Module | Purpose | Since |
|--------|--------|---------|-------|
| _(none yet -- Session 1 starts here)_ | | | |

## Findings

| ID | Session / scope | Location(s) | Kind | Copies / lines | Decision | Rationale | Commit |
|----|-----------------|-------------|------|----------------|----------|-----------|--------|
| _example_ | S0 / demo | `A.swift:10`, `B.swift:22` | near-duplicate-fn | 2x ~8 lines, 95% | tolerated | rule of three: only 2 copies, low churn risk | -- |

<!--
Append rows below per session. Keep the example row at the top as the format
reference. Do not delete rows once written.
-->

## Running totals

Update at the end of each session (Session 10 finalizes):

- Lines removed (net): _tbd_
- Consolidated: _0_  ·  Tolerated: _0_  ·  Rejected: _0_  ·  Deferred: _0_
- New shared helpers introduced: _0_
