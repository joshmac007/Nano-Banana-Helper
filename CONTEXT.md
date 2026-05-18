# Nano Banana Helper

Nano Banana Helper is a macOS workbench for staging image generation and editing jobs, routing them through provider APIs, and preserving the resulting files, costs, and history.

## Language

**Local Queue**:
The in-app work queue that tracks staged jobs, concurrency, cancellation, resume, output persistence, and history.
_Avoid_: Batch API, provider batch, discount tier

**Batch Tier**:
A provider-side asynchronous processing mode for non-urgent jobs that trades latency for lower cost or higher throughput.
_Avoid_: Local queue, normal batch, many requests

**Batch Tier Toggle**:
The shared Inspector control that chooses provider-side **Batch Tier** for the selected provider.
_Avoid_: OpenAI batch mode switch, Gemini-only toggle

**Gemini Batch Tier**:
The existing Gemini implementation of **Batch Tier** using Gemini `batchGenerateContent` jobs.
_Avoid_: Local queue

**OpenAI Batch Tier**:
The OpenAI implementation of **Batch Tier** using OpenAI's Batch API for OpenAI image generation and image edit requests.
_Avoid_: OpenAI local queue, OpenAI multi-request mode

**OpenAI Batch Request Line**:
One JSONL line inside an **OpenAI Batch Tier** submission that corresponds to one staged app task.
_Avoid_: Output, local task, variation

**OpenAI Vision File**:
A local source image or mask uploaded to OpenAI Files so it can be referenced from **OpenAI Batch Request Lines**.
_Avoid_: Output file, batch input file

**OpenAI Remote Batch**:
One provider-side OpenAI Batch API job created from a JSONL file of **OpenAI Batch Request Lines**.
_Avoid_: Local batch, local queue, task

**Remote Batch ID**:
The provider identifier for a submitted provider-side batch job.
_Avoid_: Request ID, custom ID, output ID

**Remote Request ID**:
The app-assigned identifier for one request line inside an **OpenAI Remote Batch**.
_Avoid_: Batch ID, output ID

**Partial Batch Success**:
An **OpenAI Remote Batch** outcome where some request lines produce outputs and other request lines fail or expire.
_Avoid_: Whole-batch failure

**Remote Batch Cancellation**:
A cancellation request that applies to an entire provider-side batch job after it has been submitted.
_Avoid_: Per-task remote cancel

**Images per Request**:
The OpenAI setting that asks one OpenAI image request to return multiple generated outputs.
_Avoid_: Batch size, task count

## Relationships

- The **Local Queue** can run jobs through standard provider requests or through a provider **Batch Tier**.
- The **Batch Tier Toggle** is shared by Gemini and OpenAI; provider-specific behavior lives behind the same user-facing control.
- **Gemini Batch Tier** and **OpenAI Batch Tier** are separate provider implementations of **Batch Tier**.
- **OpenAI Batch Tier** applies to OpenAI image generation and image edit requests, not to the app's generic local queuing behavior.
- One staged app task produces one **OpenAI Batch Request Line**.
- One **OpenAI Batch Request Line** can produce more than one output when **Images per Request** is greater than one.
- **OpenAI Batch Request Lines** for image edits reference **OpenAI Vision Files** instead of embedding local file bytes in the batch JSONL.
- One local batch job creates one **OpenAI Remote Batch** containing all eligible **OpenAI Batch Request Lines**.
- An **OpenAI Remote Batch** result is routed back to local tasks by each line's request identifier.
- **Partial Batch Success** completes successful local tasks while marking only failed or expired request lines as issue tasks.
- Once an **OpenAI Remote Batch** is submitted, cancellation is **Remote Batch Cancellation** and applies to the whole provider-side batch.
- All local tasks submitted through the same **OpenAI Remote Batch** share one **Remote Batch ID**.
- Each local task submitted through an **OpenAI Remote Batch** has its own **Remote Request ID** for result routing.

## Example dialogue

> **Dev:** "When the user enables **Batch Tier** for OpenAI, should we just run more local OpenAI requests?"
> **Domain expert:** "No. **OpenAI Batch Tier** means the provider-side OpenAI Batch API. The **Local Queue** should track that remote batch lifecycle."

## Flagged ambiguities

- "Batch mode" was used to mean both the app's **Local Queue** and provider-side discounted async processing; resolved: OpenAI batch mode means **OpenAI Batch Tier**.
- "`n`" and "batch" were easy to conflate; resolved: **Images per Request** controls outputs per request line, while **OpenAI Batch Tier** controls asynchronous provider processing.
- "Batch input file" and "input image file" are different concepts; resolved: **OpenAI Vision Files** are source assets, while the OpenAI Batch API input file is the JSONL request list.
- Gemini currently creates remote work per local task, but **OpenAI Batch Tier** groups the local batch into one **OpenAI Remote Batch**.
- Mixed OpenAI batch results are not whole-batch failures; resolved: use **Partial Batch Success** and preserve successful outputs.
- Per-task cancel is valid before OpenAI submission, but after submission OpenAI cancellation is **Remote Batch Cancellation**.
- Existing `externalJobName` persistence is too broad for OpenAI Batch Tier; resolved: distinguish **Remote Batch ID** from **Remote Request ID**.
- OpenAI should not get a separate visible mode; resolved: use the existing **Batch Tier Toggle** and provider-specific explanatory copy.
