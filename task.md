# Task Packet: Gemini-Only Region Edit (Replace Undocumented Binary Mask API Usage)

## Purpose

Implement a Gemini-only replacement for the current "mask inpainting" behavior.

Keep the **region selection UI** (brush/mask editor) but stop sending the binary mask PNG to Gemini as an API input.

Instead implement a **local region-edit pipeline**:

1. User paints a region (mask) locally.
2. App computes a crop around the painted region (+ margin).
3. App sends the crop image to Gemini image model with a merged prompt.
4. App receives an edited crop from Gemini.
5. App composites the edited crop back into the original image using the local mask (simple feathering).

## Confirmed Product Decisions (Locked)

These were explicitly approved by user and are not open questions:

1. **Stay on Gemini image models only** (no Imagen / Vertex AI mask API integration).
2. **Multi-input mode must be disabled when region edits are present** (do not silently pick first mask).
3. **Prompt merge must append a fixed clause** (not pure override).
4. **Simple feathering only** for local compositing (no advanced color matching for v1).

## Implementation Progress (Update After Every Subtask)

- [x] Subtask 1: Multi-input blocked when region edits exist; remove "first mask wins" fallback in `InspectorView.startBatch()`.
- [x] Subtask 2: Prompt merge helper with fixed clause (scaffolding in orchestrator).
- [x] Subtask 3: Mask coordinate normalization + accurate mask PNG generation.
- [x] Subtask 4: `RegionEditProcessor` crop/composite pipeline (simple feathering).
- [x] Subtask 5: Orchestrator region-edit branch (preprocess/send/postprocess).
- [x] Subtask 6: Remove Gemini binary-mask request payload usage.
- [x] Subtask 7: Resolution chooser + region-aware cost estimation.
- [x] Subtask 8: Validation/logging hardening.
- [ ] Subtask 9: Tests + QA checklist execution.

## Why This Change Is Required

### API reality (as of 2026-02-24)

- Gemini image docs support **semantic masking / inpainting** (prompt + image).
- Gemini docs do **not** document a user-provided binary mask image field for `generateContent`.
- Current app behavior sends the mask PNG as another `inlineData` image and assumes it is treated as a mask.

This is undocumented and unreliable.

## Current Code Snapshot (Important Anchors)

### Current mask editor stores view-space points and generates mask PNG
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Views/ImageMaskEditorView.swift`
- `DragGesture` stores `value.location` directly into `DrawingPath.points`.
- `generateMaskAndSave()` renders a PNG mask but does not correctly transform UI coordinates to source-image pixel coordinates.

### Current batch start behavior silently degrades masks in multi-input mode
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Views/InspectorView.swift`
- In `startBatch()`, multi-input mode chooses the first mask edit arbitrarily (`firstMaskURL`) and sends only that mask/prompt.

### Current Gemini request builder sends mask PNG as an additional image part
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/NanoBananaService.swift`
- `buildRequestPayload(request:)` appends `request.maskImageData` as `"inlineData"` image.

### Current orchestrator writes Gemini image response directly to output
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/BatchOrchestrator.swift`
- `handleSuccess(...)` writes `response.imageData` directly to output file (`try response.imageData.write(to: outputURL)`).
- Region-edit pipeline is not implemented today.

## Non-Goals (Do Not Implement in This Task)

1. Do not add Imagen / Vertex AI.
2. Do not attempt undocumented Gemini binary-mask upload behavior.
3. Do not implement advanced seam fixing beyond simple feathering.
4. Do not support region edits in multi-input mode (v1).
5. Do not broad-refactor unrelated UI or batch architecture.

## High-Level Design (Target State)

### New concept: Region Edit is local-guided + Gemini semantic edit

- The painted mask is **local only** (geometry + blending).
- Gemini receives:
  - prompt (merged global + per-image prompt + fixed clause)
  - cropped source image only
- Gemini returns edited crop
- App composites edited crop back into original using local mask

## Required User-Facing Behavior

### Standard batch mode (one task per image)
- Supported.
- Each image may have:
  - no region edit => full-image Gemini edit (existing flow)
  - region edit => crop/send/composite/save (new flow)

### Multi-input mode
- If any staged file has a region edit, batch start must be blocked with clear messaging.
- Do not silently drop masks.
- Do not pick first mask.

### Prompt behavior
- Global batch prompt remains the shared prompt.
- Per-image region edit prompt augments global prompt.
- A fixed clause is always appended for region-edit tasks.

## Fixed Prompt Merge Clause (Use This Exact Text for v1)

Append this clause to all region-edit requests:

`Only change the intended region in this cropped image. Preserve all unrequested details, lighting, perspective, and style consistency.`

### Prompt merge rule (required)

Given:
- `globalPrompt` from Batch panel
- `regionPrompt` from mask editor (per image)

Build final region-edit prompt:

1. If both exist and are non-empty:
   - join with clear labels and newlines.
2. If one exists:
   - use that one.
3. Always append fixed clause.

Example format:

```text
Global instructions:
<globalPrompt>

Region edit instructions:
<regionPrompt>

Only change the intended region in this cropped image. Preserve all unrequested details, lighting, perspective, and style consistency.
```

## Detailed Implementation Plan (Step-by-Step)

## Phase 1: Lock Behavior and Data Contracts

### 1.1 Add explicit region-edit semantics in models

Files:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Models/BatchStagingManager.swift`
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Models/Models.swift`

Actions:
- Keep existing `StagedMaskEdit`, but redefine semantics in comments/docs:
  - `maskData` = local composite mask, not API mask.
- Add an explicit task-level mode for downstream branching (recommended enum):
  - `fullImage`
  - `regionEdit`
- Ensure `ImageTask` can persist enough data for region-edit execution:
  - local mask PNG (`Data`)
  - region prompt (`String?`)
  - drawing paths (optional for editor reopen; mask PNG is minimum for processing)

Compatibility:
- Preserve decoding of existing persisted tasks/history with `maskImageData`.
- If old saved tasks exist, treat `maskImageData` as local mask for region editing fallback.

### 1.2 Update naming/comments to prevent future hallucination

Replace misleading comments that say:
- "inpainting via mask image sent to API"

With:
- "region edit mask used locally for crop/composite; Gemini receives crop + prompt only"

## Phase 2: Multi-Input Safety (Disable Region Edit in Multi-Input Mode)

### 2.1 Add explicit validation in staging manager

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Models/BatchStagingManager.swift`

Add derived property:
- `hasAnyRegionEdits` (true if any `stagedMaskEdits` exists for staged files)

Update validation behavior:
- `canStartBatch` must be false if:
  - `isMultiInput == true`
  - `hasAnyRegionEdits == true`

Add clear reason property (recommended):
- `startBlockReason: String?`

### 2.2 Enforce in `InspectorView.startBatch()`

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Views/InspectorView.swift`

Before building tasks:
- If `stagingManager.isMultiInput && stagingManager.hasAnyRegionEdits`, show alert/toast/status and `return`.

Remove current silent behavior:
- Delete logic that arbitrarily picks `firstMaskURL` in multi-input mode.

### 2.3 UI messaging

Files:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Views/InspectorView.swift`
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Views/StagingView.swift`

Add messaging:
- "Region Edit is only available in standard batch mode (one output per input image)."

## Phase 3: Fix Mask Coordinate Fidelity (Critical Correctness)

### 3.1 Store normalized paths instead of raw overlay points

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Views/ImageMaskEditorView.swift`

Problem today:
- `DragGesture` stores `value.location` directly in view coordinates.
- Final PNG generation assumes those points can be reused at image resolution.

Required change:
- Track the displayed image rect inside the `scaledToFit` container.
- Convert pointer points into normalized image coordinates (`x`, `y` in `0...1`) when drawing.
- Ignore points outside visible image rect.

Implementation guidance:
- Introduce a display-geometry helper that computes:
  - rendered image frame within `GeometryReader`
  - scale factor
  - letterboxing offsets
- Store normalized points in `DrawingPath` (preferred), or store both:
  - `viewPoints` (legacy)
  - `normalizedPoints` (new canonical)

### 3.2 Render preview and output mask from the same normalized model

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Views/ImageMaskEditorView.swift`

Requirements:
- On-screen preview:
  - convert normalized points -> current display rect coordinates
- Saved mask PNG:
  - convert normalized points -> source image pixel coordinates

Result:
- Correct alignment independent of window size / panel resize.

### 3.3 Editor copy changes (Gemini-only contract)

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Views/ImageMaskEditorView.swift`

Update copy:
- Title: `Region Edit (Gemini)` or `Guided Region Edit`
- Prompt placeholder: describe edit in selected region (not "masked area" as API mask)

## Phase 4: Local Region Processing Pipeline (Crop + Composite)

### 4.1 Add a dedicated service for region processing

Create file:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/RegionEditProcessor.swift`

Why a separate service:
- Keep `BatchOrchestrator` readable.
- Make geometry/compositing testable.

### 4.2 `RegionEditProcessor` required responsibilities

Input:
- original image bytes or URL
- local mask PNG bytes
- desired processing size (`1K` / `2K` / `4K` chosen later)

Output:
- preflight metadata: crop rect, crop aspect, target pixel size
- crop image data for Gemini
- composite final full image data after Gemini returns edited crop

Required functions (suggested, names can vary):
- `decodeImage(...)`
- `maskBoundingBox(from maskData: Data) -> CGRect?`
- `expandedCropRect(for bbox: CGRect, imageSize: CGSize, marginFraction: CGFloat) -> CGRect`
- `cropImage(...) -> CGImage/NSImage/Data`
- `cropMask(...) -> CGImage`
- `resizeGeminiOutputToCropRect(...)`
- `featherMask(...) -> alpha mask`
- `composite(original:editedCrop:mask:cropRect:) -> Data`

### 4.3 Bounding box and crop rules (must be deterministic)

Rules:
- Compute bbox from non-black / white mask pixels.
- If bbox is empty, fail with explicit error (`empty region selection`).
- Expand by margin (e.g. `10%` to `25%`, choose one and document it).
- Clamp crop rect to source image bounds.
- Maintain rectangular crop only (v1).

### 4.4 Simple feathering (v1, approved)

Use simple edge feathering only:
- Blur alpha mask slightly (e.g. Gaussian blur or box blur equivalent)
- Composite edited crop over original using feathered alpha

Do not implement:
- color transfer
- Poisson blending
- seam patching

## Phase 5: Gemini Request Path Changes (Stop Sending Binary Mask)

### 5.1 Remove mask append from `buildRequestPayload`

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/NanoBananaService.swift`

Current behavior to remove:
- Appending `request.maskImageData` as an extra `inlineData` image part.

Target behavior:
- Gemini request contains:
  - prompt text
  - one image for region edit (the crop)
  - or normal inputs for existing flows

Keep:
- `imageConfig`
- `generationConfig`
- `system_instruction` support

### 5.2 Clarify `ImageEditRequest` semantics

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/NanoBananaService.swift`

Update request struct as needed:
- Remove `maskImageData` if no longer used by API layer, OR
- Keep it temporarily but mark deprecated / local-only and do not serialize into Gemini payload

Preferred:
- Remove from API request struct and keep region-edit data in orchestrator/local processor layer.

## Phase 6: Batch Orchestrator Region-Edit Branch

### 6.1 Add a region-edit preprocessing path before API submission

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/BatchOrchestrator.swift`

For each task:
- If region-edit:
  - load original image
  - compute crop + target size
  - generate crop image data / temp file (choose implementation)
  - construct Gemini request for crop
- If full-image:
  - current path

Important:
- Maintain security-scoped file access correctness while reading originals.

### 6.2 Add prompt merge helper (required)

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/BatchOrchestrator.swift`

Implement pure function (recommended):
- `mergedPrompt(globalPrompt: String, regionPrompt: String?) -> String`

Must append fixed clause exactly (see above).

### 6.3 Postprocess region-edit output before saving

Current behavior:
- writes `response.imageData` directly to output path

Target behavior for region-edit:
- decode Gemini edited crop
- resize to crop rect dimensions in original image space
- composite onto original using local mask (feathered)
- write final full image

Only full-image tasks should continue using direct write path.

### 6.4 History and persistence

Files:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Models/Models.swift`
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/BatchOrchestrator.swift`

Ensure history records:
- final output path (full image)
- prompt used (merged prompt or user-visible prompt strategy)
- optional note/flag that it was a region edit (recommended for future debugging)

## Phase 7: Resolution Selection for Crop Processing (Quality + Cost)

### 7.1 Add a deterministic resolution chooser

File (preferred):
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/RegionEditProcessor.swift`
or helper in orchestrator

Inputs:
- user selected max size (`1K`, `2K`, `4K`)
- crop rect pixel dimensions
- crop aspect ratio

Output:
- actual processing size used for Gemini request

Rules:
- Never exceed user-selected max.
- Prefer no upscaling of Gemini result into crop target when possible.
- If crop target is smaller than chosen size, downscaling is acceptable.

### 7.2 Cost estimation must use actual region processing size

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/BatchOrchestrator.swift`

Current cost uses `settings.imageSize` only.

Target:
- full-image task => current behavior
- region-edit task => use actual chosen processing size (`1K/2K/4K`) for that task

Add task-level metadata if needed to store chosen size.

## Phase 8: API-Safe Validation and Logging Hardening

### 8.1 Validate image counts for Gemini model

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Models/BatchStagingManager.swift`
or orchestrator submit validation

Add cap checks aligned with current Gemini image model limits.
- Include region-edit crop submissions in count logic.
- Multi-input + region edit is already blocked, so simpler than current behavior.

### 8.2 Improve batch size validation for masked/region edits

File:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/NanoBananaService.swift`

Current issue:
- validation uses raw input bytes only and excludes mask and base64 expansion.

Target:
- validate based on actual bytes of submitted crop image(s)
- add conservative overhead for base64 expansion and JSON
- fail early with actionable error

### 8.3 Stop logging full base64 payloads

Files:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Services/NanoBananaService.swift`
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana Helper/Models/Models.swift` (`LogManager`)

Current behavior logs full request JSON body, which includes base64 images.

Replace with request summary logging:
- model name
- request mode (`fullImage` / `regionEdit`)
- number of input images
- crop/full dimensions
- byte counts
- selected processing size
- prompt length(s) (optional)

Do not log raw base64 image data.

## Phase 9: Testing Plan (Must-Have)

## 9.1 Unit tests (new)

Create tests in:
- `/Users/joshmcswain/Documents/Projects/NanoBananaPro-Batch/Nano Banana Helper/Nano Banana HelperTests/`

Required unit tests:

1. Mask bbox extraction
- Empty mask => nil/error
- Single painted region => correct bbox
- Multiple islands => bbox contains all (v1 rectangle behavior)

2. Crop expansion + clamp
- Bbox near edges clamps correctly
- Margin expansion deterministic

3. Normalized path transform
- UI point -> normalized -> source pixel -> expected location
- Resized window produces same saved mask alignment

4. Prompt merge
- global only
- region only
- both
- fixed clause appended exactly once

5. Resolution chooser
- crop smaller than 1K
- crop between 1K and 2K
- crop larger than selected max

6. Cost estimation
- region-edit task uses actual chosen processing size
- full-image task unchanged

## 9.2 Integration-style tests (where feasible)

1. Standard batch + region edit task path
- task enters region-edit branch
- Gemini response path composites final full image

2. Multi-input + region edits blocked
- `canStartBatch` false and clear reason/message present

3. No API mask upload in payload
- build payload assertion: no second mask `inlineData` part added from local mask field

## 9.3 Manual QA checklist

1. Standard batch, 1 image, region edit
- edit aligns with painted region
- minimal seam artifacts
- final image dimensions match original

2. Standard batch, multiple images, mixed:
- image A region edit
- image B no region edit
- global prompt set
- per-image prompt on A only
- all outputs saved correctly

3. Multi-input mode with any region edit
- start disabled or blocked
- clear user-facing message

4. Resize app window before saving region edit
- saved mask still aligns (tests normalized geometry fix)

5. Cost display sanity
- region-edit small crop with user max 4K does not necessarily charge as 4K if chooser picks lower size

## Acceptance Criteria (Definition of Done)

1. Region-edit tasks no longer send local mask PNG as Gemini API image input.
2. Region-edit output is composited locally into original image with simple feathering.
3. Standard batch mode supports multiple images with independent region edits.
4. Multi-input mode is blocked when region edits are present (no silent first-mask behavior).
5. Prompt merge uses global + per-image prompt + fixed clause.
6. Mask alignment is correct after window resize / scaled display.
7. Cost estimate uses actual chosen region processing size.
8. Request logging does not include base64 image payloads.
9. Tests added for geometry, prompt merge, resolution selection, and multi-input blocking.

## Implementation Order (Do in This Sequence)

1. Multi-input blocking + remove first-mask fallback.
2. Prompt merge helper with fixed clause.
3. Mask coordinate normalization in editor.
4. `RegionEditProcessor` (bbox, crop, resize, feather, composite).
5. Orchestrator region-edit branch (preprocess + postprocess).
6. Remove Gemini binary-mask payload usage.
7. Resolution chooser + cost update.
8. Validation hardening (count/size).
9. Logging hardening (no base64 request logs).
10. Tests + manual QA pass.

## Anti-Hallucination Notes for Future AI (Context Compaction Safety)

1. Do **not** assume Gemini supports uploaded binary edit masks. It is not the documented contract for Gemini image models in this task.
2. The local mask remains useful for crop selection and compositing. Do not delete the editor UI.
3. The first implementation target is **standard batch mode only** for region edits.
4. Multi-input region edits are intentionally blocked in v1.
5. The fixed prompt clause is required and already user-approved.
6. Feathering should stay simple in v1.
7. Existing code currently stores `maskImageData`; treat it as local mask/composite data, not API mask.
8. Do not broad refactor unrelated batch/network code unless required for this feature.

## Reference Links (API Research)

- Gemini image generation (semantic masking/inpainting examples): https://ai.google.dev/gemini-api/docs/image-generation
- Gemini batch mode: https://ai.google.dev/gemini-api/docs/batch-mode
- Gemini vision/image understanding (separate from edit-mask input support): https://ai.google.dev/gemini-api/docs/vision
