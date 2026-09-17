# Direct DeepSeek and GPT-5.6 v0.76 Design

**Status:** Approved for implementation planning

**Date:** 2026-09-17

**Repository:** `weave-os/router` fork

**Parent routing artifact:** `internal/router/cluster/artifacts/v0.75`

## Summary

Add DeepSeek as a first-class, directly authenticated provider and publish a
candidate `v0.76` cluster-routing bundle that adds GPT-5.6 Sol, Terra, and Luna
without changing the v0.75 cluster geometry. The direct DeepSeek API becomes
the preferred binding for the DeepSeek V4 models it serves, while the existing
third-party providers remain ordered fallbacks.

The artifact work is an additive overlay, not a retrain. `v0.76/centroids.bin`
must be byte-identical to `v0.75/centroids.bin`. New quality columns come from
measurements made against prompts assigned to the existing sixteen clusters,
then calibrated onto v0.75's quality scale with conservative clamping. No
unmeasured quality vector may be presented as measured data.

## Goals

- Register a canonical `deepseek` provider using DeepSeek's direct
  OpenAI-compatible Chat Completions API.
- Support deployment-level and per-installation DeepSeek credentials through
  the same provider-key paths used by the other OpenAI-compatible providers.
- Prefer direct DeepSeek bindings while retaining current provider fallbacks.
- Route to the current DeepSeek API models using stable router catalog IDs:
  - `deepseek/deepseek-v4-flash` -> `deepseek-flash`
  - `deepseek/deepseek-v4-pro-0813` -> `deepseek-v4-pro`
- Add `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna` to a new v0.76
  cluster roster.
- Replace the retired, untiered `deepseek/deepseek-v4-pro` cluster target with
  the routable `deepseek/deepseek-v4-pro-0813` target.
- Keep v0.75's sixteen centroids and embedding metadata unchanged.
- Generate all v0.76 quality, operational-axis, feature, ranking, registry,
  and metadata files from reviewed inputs through one deterministic command.
- Keep `artifacts/latest` on v0.75 until v0.76 passes offline and live release
  gates.

## Non-goals

- Do not retrain or recluster prompts.
- Do not change the centroid binary format, embedder, cluster count, or
  per-cluster default routing knobs.
- Do not enable DeepSeek's native thinking mode in this change. Thinking-mode
  tool loops require provider-specific handling for `tool_choice` and replay
  of `reasoning_content`; ordinary Chat Completions, streaming, and function
  tools remain in scope.
- Do not add a dedicated DeepSeek HTTP adapter package. The API is compatible
  with the existing `internal/providers/openaicompat` adapter for the scoped
  behavior.
- Do not remove Makora, Together, Fireworks, OpenRouter, or Wafer fallbacks.
- Do not promote v0.76 by editing `internal/router/cluster/artifacts/latest` in
  the artifact-construction change.
- Do not use guessed or undocumented prices, performance numbers, or quality
  vectors.

## Current State

The fork already contains more GPT-5.6 support than the original high-level
proposal assumed:

- `internal/router/catalog/catalog.go` defines Sol, Terra, and Luna with direct
  OpenAI bindings, context windows, standard pricing, long-context pricing,
  cache pricing, and fast-tier pricing.
- `internal/router/model.go` defines their reasoning capabilities.
- `internal/providers/openai` supports their normal OpenAI and ChatGPT/Codex
  dispatch paths.
- Generated installer/statusline price tables already contain the three
  models.

The missing GPT-5.6 work is therefore cluster-roster membership and the data
required to score the models in the v0.75 geometry.

The fork also already catalogs DeepSeek V4 Flash and Pro through third-party
providers. v0.75 contains both in its registry and feature tables, but the bare
`deepseek/deepseek-v4-pro` catalog entry is intentionally untiered. The cluster
scorer resolves catalog bindings before considering the artifact's recorded
provider and drops untiered catalog models, so that bare Pro entry is no longer
a routable candidate. The current routable target is
`deepseek/deepseek-v4-pro-0813`.

The direct DeepSeek API currently lists `deepseek-flash` and
`deepseek-v4-pro`. It uses an OpenAI-compatible `/chat/completions` surface and
reports cache-hit and cache-miss token usage separately.

## Architecture

### Provider identity and composition

Add a `ProviderDeepSeek = "deepseek"` constant in
`internal/providers/provider.go` and include it in all provider-owned maps:

- `ProviderFamilies`: `FamilyOpenAICompat`
- `APIKeyEnvVars`: `DEEPSEEK_API_KEY`
- `CacheTTL`: the existing conservative five-minute OpenAI-compatible window

Add a `DeepSeekBaseURL = "https://api.deepseek.com"` constant to the
OpenAI-compatible adapter. Register the
provider in `cmd/router/main.go` with `registerDeploymentKeyedProvider`, using
`DEEPSEEK_BASE_URL` as the optional endpoint override and
`upstreamIDsForProvider` with the new DeepSeek provider constant as the
model-ID map.

This keeps composition in `cmd/router/main.go`, provider identity in the inner
`providers` package, and HTTP behavior in the existing adapter. No new layer
or cross-adapter dependency is introduced.

The provider is always placed in `providerMap`. Without a deployment key it is
BYOK-only; with `DEEPSEEK_API_KEY` it joins `envKeyedProviders` and becomes
eligible for automatic routing. Managed BYOK-only mode continues to suppress
deployment credentials through the existing registration helper.

### Catalog bindings

Add a direct DeepSeek binding as the first `ProviderBinding` for each supported
logical model. Catalog order is the provider preference order, so the direct
binding wins whenever DeepSeek is enabled and the existing bindings remain
fallbacks.

| Router catalog ID | Direct upstream ID | Input USD / 1M | Cached input USD / 1M | Output USD / 1M |
| --- | --- | ---: | ---: | ---: |
| `deepseek/deepseek-v4-flash` | `deepseek-flash` | 0.14 | 0.028 | 0.28 |
| `deepseek/deepseek-v4-pro` | `deepseek-v4-pro` | 1.74 | 0.145 | 3.48 |
| `deepseek/deepseek-v4-pro-0813` | `deepseek-v4-pro` | 1.74 | 0.145 | 3.48 |

The bare Pro entry remains untiered for passthrough and existing session-pin
compatibility. The dated Pro entry remains the only routable Pro catalog row.
Both map to the current direct API alias because direct DeepSeek does not expose
the historical provider-specific dated name.

The cache multiplier stored in `catalog.Pricing` is derived exactly from the
documented prices:

- Flash: `0.028 / 0.14 = 0.20`
- Pro: `0.145 / 1.74`

No parallel pricing table is added. Billing, telemetry, planner cost math, and
generated installer price data continue to consume the catalog.

### Direct-API request behavior

The direct provider uses the current OpenAI-compatible preparation and stream
translation paths. Existing response translation already recognizes both
`reasoning` and `reasoning_content`, including streamed DeepSeek output.

DeepSeek native thinking mode remains disabled for this scope because the API
has additional conversation invariants:

- thinking-mode tool requests reject `tool_choice`;
- assistant `reasoning_content` must be retained across tool-call turns;
- tool-call assistant messages require non-null content.

The existing DeepSeek model specs are zero-capability OpenAI-compatible specs,
so the router does not synthesize `thinking` or `reasoning_effort` for them.
Provider tests must lock this behavior: adding direct credentials must not
silently enable a request shape the translation layer cannot round-trip.

### Artifact source of truth

Add a deterministic overlay builder under `scripts/` and a reviewed JSON input
manifest under `internal/router/cluster/artifacts/v0.76/inputs/`. The manifest
is the source of truth for new or renamed model columns and contains:

- source model ID and destination model ID;
- sixteen observed or calibrated quality values;
- input and output price per 1,000 tokens;
- measured TTFT in seconds;
- measured output throughput in tokens per second;
- measured verbosity tokens or explicit `null`;
- evidence type (`measured`, `same-upstream-alias`, or `proxy`);
- measurement source identifier and collection date;
- sample count for each cluster when quality is measured;
- proxy source and reason when evidence type is `proxy`.

The builder reads v0.75 and the manifest, validates every input, and writes the
complete v0.76 bundle in one operation. It must refuse to overwrite an existing
generated v0.76 artifact file unless an explicit development-only flag is
supplied. A directory containing only the reviewed `inputs/` manifest is a
valid first-run destination; the committed generated artifact is write-once.

The builder performs these transformations:

1. Copy `centroids.bin` byte-for-byte from v0.75.
2. Copy unchanged v0.75 model data.
3. Remove the retired bare DeepSeek Pro roster entry.
4. Add `deepseek/deepseek-v4-pro-0813`, preserving the measured quality profile
   of the same underlying Pro API model only when the manifest marks it as a
   `same-upstream-alias` transformation.
5. Add the three measured GPT-5.6 columns.
6. Build `quality_means.json` from the final model-by-cluster table.
7. Build `model_axes.json` from the final operational data.
8. Build `model_features.json` as the exact model-centric repackaging of the
   previous two files.
9. Recompute `rankings.json` using the runtime-equivalent v2 blend and v0.75's
   default routing knobs.
10. Write `model_registry.json` and `metadata.yaml` with the final roster,
    provider provenance, evidence description, checksums, and generator name.

The generator must use stable model ordering, sorted JSON keys where applicable,
fixed numeric serialization, and no wall-clock value except the reviewed date
already present in the manifest. Running it twice from the same checkout and
manifest must produce byte-identical output.

## Quality Measurement and Calibration

### Prompt assignment

Quality evaluation uses the frozen v0.75 geometry. Prompts are embedded with
`jina-v2-base-code-int8` using the runtime's truncation, pooling, and
normalization contract, then assigned to the nearest existing v0.75 centroid.
Centroids are never recomputed.

The committed `register_probes.jsonl` is suitable for distribution checks but
does not contain ground-truth quality labels. It must not be used alone to
claim model quality. Quality evidence must come from the existing private eval
harness or another reviewed benchmark set with deterministic graders and must
record enough prompt identity to reproduce cluster sample counts without
committing private prompts or identifiers to this public repository.

### Score normalization

For each new model and cluster:

1. Aggregate observed task scores using the same metric direction as the
   benchmark source, producing an observed cluster mean and sample count.
2. Use incumbent models evaluated on the same prompts as anchors.
3. Fit a monotonic piecewise-linear mapping from observed anchor means onto
   their v0.75 `quality_means` values.
4. Interpolate the new model's observed mean through that mapping.
5. Clamp below the minimum and above the maximum measured anchor values; never
   extrapolate beyond the incumbent range.
6. Cap the calibrated result at the best incumbent value in that cluster so a
   sparse new-model measurement cannot become a synthetic new maximum.
7. Record the calibrated value and cluster sample count in the manifest.

Clusters without sufficient direct evidence must use an explicitly reviewed
proxy vector or block artifact completion. A proxy is allowed only when the
manifest names the source and rationale. The v0.76 metadata must distinguish
proxies from measured columns. The implementation must not silently substitute
a proxy when measurements are missing.

### Operational axes

TTFT and throughput are measured against the actual binding intended for the
release:

- GPT-5.6 models through direct OpenAI;
- DeepSeek models through direct DeepSeek.

Measurements use repeated streaming requests with a fixed prompt set and
output target. The manifest records the median TTFT and median non-reasoning
output-token throughput after warm-up. Failed, throttled, or truncated requests
are excluded from the timing aggregate but counted in the measurement report.

Verbosity is the median output-token count on the fixed verbosity probe set. If
the probe set was not run, the value is explicit `null`, causing the scorer's
existing median fallback rather than a fabricated number.

Catalog prices are authoritative for routing-cost axes. The artifact stores
per-1,000-token values derived from the catalog's standard price, not fast-tier
or long-context price, matching the current artifact schema.

## v0.76 Roster

The v0.76 roster is the v0.75 roster with these changes:

- Add `gpt-5.6-sol` with provider provenance `openai`.
- Add `gpt-5.6-terra` with provider provenance `openai`.
- Add `gpt-5.6-luna` with provider provenance `openai`.
- Keep `deepseek/deepseek-v4-flash`, changing provider provenance to
  `deepseek`.
- Replace `deepseek/deepseek-v4-pro` with
  `deepseek/deepseek-v4-pro-0813`, with provider provenance `deepseek`.
- Keep every other v0.75 entry unchanged.

Registry provider provenance does not prevent fallback routing: for cataloged
models, `cluster.resolveProviderFor` walks the catalog's ordered bindings and
rewrites the candidate provider to the first available binding. The registry
field remains accurate documentation of the preferred release binding.

## Files and Ownership

Expected production changes:

- `internal/providers/provider.go`: canonical provider identity, family, key
  environment variable, and cache TTL.
- `internal/providers/openaicompat/client.go`: DeepSeek default base URL.
- `cmd/router/main.go`: composition-root registration.
- `internal/router/catalog/catalog.go`: preferred direct bindings and pricing.
- `docs/CONFIGURATION.md`: `DEEPSEEK_API_KEY` and `DEEPSEEK_BASE_URL`.
- `scripts/build_v076_gpt56_deepseek_overlay.py`: deterministic artifact
  overlay builder and validations.
- `internal/router/cluster/artifacts/v0.76/inputs/model_measurements.json`:
  reviewed measurement/calibration manifest.
- `internal/router/cluster/artifacts/v0.76/{centroids.bin,model_registry.json,quality_means.json,model_axes.json,model_features.json,rankings.json,metadata.yaml}`:
  generated candidate bundle.

Expected tests:

- `internal/providers/families_test.go`: DeepSeek is present in the provider
  family and environment-variable contract.
- `internal/providers/openaicompat/client_test.go`: default/base-path behavior
  remains compatible with `/chat/completions`.
- `internal/router/catalog/catalog_test.go`: direct binding order, upstream ID,
  direct price, cache multiplier, and third-party fallback selection.
- `cmd/router/main_test.go` or the closest existing composition test: provider
  registration and upstream-ID map coverage.
- `internal/router/cluster/artifacts_test.go`: v0.76 loads, all roster models
  have sixteen quality cells and axes, and the retired bare Pro target is not
  deployed.
- `internal/router/cluster/model_features_test.go`: generalize the equivalence
  gate so v0.76 features exactly match its quality and axes files.
- A script-level test fixture proving validation failures and byte-identical
  repeated output.

Generated installer/statusline files are regenerated with `make generate` only
if the catalog-derived output changes. The GPT-5.6 rows already exist; DeepSeek
logical-model prices should remain unchanged unless the preferred direct price
changes the primary catalog price.

## Validation and Release Gates

### Provider and catalog gates

- `go test ./internal/providers/...`
- `go test ./internal/router/catalog/...`
- focused composition-root tests under `./cmd/router`
- a local mock-server request proving a DeepSeek decision sends the mapped
  upstream model ID and Bearer credential to `/chat/completions`
- fallback tests proving the same logical model resolves to the next existing
  binding when `deepseek` is unavailable or excluded

### Artifact integrity gates

- SHA-256 of v0.76 `centroids.bin` equals v0.75 exactly.
- Both centroid files are byte-for-byte equal with `cmp`.
- v0.76 loads through `cluster.LoadBundle`.
- Every deployed model has exactly sixteen finite quality values.
- Every deployed model has an operational-axis record.
- `model_features.json` reproduces `quality_means.json` and `model_axes.json`
  exactly for every deployed model.
- `rankings.json` is reproducible from the same inputs and runtime blend.
- The builder produces no diff on a second run.
- Metadata lists the exact roster, direct provider, parent version, evidence
  sources, and frozen-geometry checksum.

### Routing behavior gates

Run the repository's routing report over the committed probe corpus and the
1,000-prompt diff fixture. Review, per cluster and overall:

- top-1 and top-3 model distribution;
- changes relative to v0.75;
- share won by each new model;
- cost, TTFT, throughput, and quality deltas;
- conversational/trivial, coding, and agentic-tool register distributions;
- any cluster in which a new model dominates despite sparse evidence.

No numeric top-1 agreement threshold is imposed because adding candidates is
intended to change some decisions. Release review instead requires every
changed winner to be explainable by measured quality and operational axes. A
new model that wins most clusters because of a proxy, missing axis, or scale
error blocks promotion.

### Repository gates

- `make inference-boundary`
- `make generate`
- `git diff --check`
- focused Go tests for changed packages
- `make precommit`
- the real-provider smoke scenario if direct credentials are available; when
  unavailable, the recorded mock-server conformance test is required and the
  missing live check is stated in v0.76 metadata/release notes

## Promotion

The first v0.76 change lands as `status: candidate` and does not edit
`artifacts/latest`. Promotion is a separate reviewed change after:

1. artifact integrity and repository gates pass;
2. the offline routing report is approved;
3. direct DeepSeek smoke requests pass for both models, including one streaming
   tool-call turn;
4. v0.76 completes a live bake-off against v0.75 without unacceptable quality,
   latency, error-rate, or distribution regressions.

The promotion change edits only `internal/router/cluster/artifacts/latest`,
updates candidate metadata with the promoted date/status if repository policy
permits mutating candidate metadata before freeze, and redeploys. If artifact
directories are treated as immutable immediately after their first commit, the
promotion status belongs in the release/PR record and `latest` remains the only
repository edit.

## Failure Handling

- Missing or malformed measurement data stops the generator; it never fills a
  zero or implicit proxy.
- Missing quality, axes, or feature data stops bundle loading through existing
  fail-fast validation.
- An unconfigured direct DeepSeek key leaves the provider BYOK-only and allows
  catalog fallback selection.
- No provider capable of serving a model causes the existing availability
  filter to drop that candidate.
- Direct DeepSeek upstream errors use the generic adapter's existing typed
  classification and failover path; no special fail-open route is added.
- A compatibility failure specific to DeepSeek thinking mode does not trigger
  ad hoc request rewriting in this change; native thinking remains disabled.

## Security and Public-Repository Constraints

- Never commit DeepSeek or OpenAI credentials, raw request bodies, private
  prompts, customer identifiers, organization names, or internal ticket links.
- Measurement manifests contain aggregate values and non-sensitive source IDs,
  not proprietary eval content.
- Tests use local HTTP servers and synthetic credentials.
- Logs include provider/model/status context but never authorization headers or
  full keys.

## Acceptance Criteria

The change is ready for candidate review when all of the following are true:

- `deepseek` is a canonical, boot-valid OpenAI-compatible provider.
- Deployment and BYOK DeepSeek credentials resolve through existing ownership
  and encryption paths.
- Both DeepSeek logical models map to the documented direct upstream IDs.
- Direct DeepSeek is preferred and existing provider fallbacks still work.
- v0.76 adds all three GPT-5.6 models and the routable dated DeepSeek Pro model.
- v0.76 centroids are byte-identical to v0.75.
- Every v0.76 model has sixteen quality values and one operational-axis record.
- Feature, quality, axes, ranking, registry, and metadata files come from the
  deterministic builder and reproduce byte-identically.
- New quality values are measured/calibrated or explicitly documented proxies;
  no implicit substitution exists.
- v0.76 loads and routes in tests without changing the default `latest`
  pointer.
- Focused, architecture, generation, formatting, and precommit checks pass.
- Promotion remains gated on offline report review and a live v0.75/v0.76
  bake-off.

## References

- DeepSeek models and pricing:
  <https://api-docs.deepseek.com/quick_start/pricing>
- DeepSeek model-list endpoint and current direct model IDs:
  <https://api-docs.deepseek.com/api/list-models>
- DeepSeek Chat Completions request and response contract:
  <https://api-docs.deepseek.com/api/create-chat-completion>
- DeepSeek thinking-mode tool-call requirements:
  <https://api-docs.deepseek.com/guides/thinking_mode>
- Local artifact format and trainer contract:
  `internal/router/cluster/artifacts/README.md`
