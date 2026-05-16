# Nano Banana Audit Fixes

## Objective

Implement the five audited Nano Banana Helper reliability fixes with tight, verified slices: Swift 6 concurrency readiness, OpenAI mask batching safety, last-project deletion protection, history resume output-folder preservation, and asynchronous staging thumbnails.

## Original Request

Use GoalBuddy to build out the audited issues with subagents, then reviewers afterwards, and use GitNexus when needed to check the effects of changes so the work stays tight and controlled.

## Intake Summary

- Input shape: `existing_plan`
- Audience: Nano Banana Helper app owner and end users running high-throughput image batches.
- Authority: `approved`
- Proof type: `test`
- Completion proof: all five audited findings are addressed by scoped code changes, focused regression tests, relevant app/unit build checks pass, Swift 6 readiness is either green or has a documented remaining compiler-error receipt, and final Judge review confirms the diff stays inside approved scope.
- Likely misfire: GoalBuddy could produce plans, broad refactors, or partial fixes without actually closing all five audited behaviors.
- Blind spots considered: GoalBuddy agent availability may not match Codex subagent role names; GitNexus may be unavailable or stale; Swift 6 may require multiple follow-up corrections after the first compiler-error layer; UI thumbnail work must not regress bookmark access; output-folder resume must respect sandbox rules rather than weakening them.
- Existing plan facts:
  - P1: README markets Swift 6 while the Xcode project sets `SWIFT_VERSION = 5.0`; a Swift 6 override build fails on actor-isolation errors around helper/model boundaries such as `AppPaths.bookmark(for:)`.
  - P2: OpenAI non-multi-input image mode applies one mask to every staged file, and OpenAI Batch Tier validation can fail the whole submission when one source/mask pair mismatches.
  - P2: Settings can delete the final project even though Sidebar and ProjectList disable that path; `ProjectManager.deleteProject` can leave `currentProject` nil.
  - P2: Remote history resume entries can lack both `outputImagePath` and `outputDirectoryBookmark`, so the resumed batch cannot recover the original output folder and can fall into recovery output handling.
  - P2: `StagedImageCell.thumbnail` reads full image data synchronously during SwiftUI rendering; Results already has an async cached ImageIO-thumbnail loader pattern to reuse.
  - The run should use subagents for bounded implementation and Judge-style reviewers after risky or phase-complete slices.
  - Use GitNexus impact/change detection when available before editing symbols and before final completion; if unavailable, record that as a blocker or fallback receipt instead of pretending it ran.

## Goal Kind

`existing_plan`

## Current Tranche

Complete this fix tranche end to end. The PM should validate agent and GitNexus readiness, divide the five fixes into the largest safe useful implementation slices, run bounded Worker subagents where GoalBuddy agents are available, run Judge reviewers after slices or phase boundaries, verify with focused tests and builds, and continue until the final audit proves all five original findings are closed.

## Non-Negotiable Constraints

- Do not edit implementation files without an active Worker task with explicit `allowed_files`.
- Use GitNexus impact analysis before modifying functions/classes/methods when GitNexus is available; warn and pause on HIGH or CRITICAL impact.
- Run `gitnexus_detect_changes()` before final completion when GitNexus is available.
- Preserve app sandbox and security-scoped bookmark behavior; do not weaken access controls for convenience.
- Keep changes narrow and repo-patterned; no broad refactors, dependency churn, or unrelated UI redesign.
- Add or update focused regression tests for each behavior where practical.
- Do not mark the goal complete until all five audited findings have either passed verification or have a documented blocker accepted by Judge.

## Stop Rule

Stop only when a final audit proves the full original outcome is complete.

Do not stop after planning, discovery, or Judge selection if the user asked for working software or automation and a safe Worker task can be activated.

Do not stop after a single verified Worker package when the broader owner outcome still has safe local follow-up work. Advance the board to the next highest-leverage safe Worker package and continue unless a phase, risk, rejected-verification, ambiguity, or final-completion review is due.

Do not create one Worker/Judge pair per repeated file, table, route, or helper. Put repeated same-shape work into one Worker package and review the package as a whole.

## Slice Sizing

Safe means bounded, explicit, verified, and reversible. It does not mean tiny.

A good task is the largest safe useful slice.

Small is not the goal. Useful is the goal.

A Worker should finish the whole assigned slice. A Judge should judge the whole assigned slice. A PM should reorient the board when tasks are safe but not moving the outcome.

## Canonical Board

Machine truth lives at:

`docs/goals/nano-banana-audit-fixes/state.yaml`

If this charter and `state.yaml` disagree, `state.yaml` wins for task status, active task, receipts, verification freshness, and completion truth.

## Run Command

```text
/goal Follow docs/goals/nano-banana-audit-fixes/goal.md.
```

## PM Loop

On every `/goal` continuation:

1. Read this charter.
2. Read `state.yaml`.
3. Run the bundled GoalBuddy update checker when available and mention a newer version without blocking.
4. Re-check the intake: original request, input shape, authority, proof, blind spots, existing plan facts, and likely misfire.
5. Work only on the active board task.
6. Assign Scout, Judge, Worker, or PM according to the task.
7. Write a compact task receipt.
8. Update the board.
9. If safe local work remains, choose the next largest reversible Worker package and continue unless blocked.
10. If a problem, suggestion, or follow-up should become a repo artifact, create an approved issue/PR or ask the operator whether to create one.
11. Review at phase, risk, rejected-verification, ambiguity, or final-completion boundaries.
12. Finish only with a Judge/PM audit receipt that maps receipts and verification back to the original user outcome and records `full_outcome_complete: true`.
