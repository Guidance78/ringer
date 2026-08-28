---
name: ringer
description: >-
  Orchestrate verified Ringer worker runs through ringer.py. Load before any
  model-calling command, agent CLI invocation, conversational or evaluation
  harness, edit-test-edit loop, multi-file change, manifest design, worker
  routing, swarm-pattern choice, or failed worker-output diagnosis. Use a
  one-task manifest even for small repeated fixes; use the Codex managed-child
  completion bridge for every real Ringer run so it never polls. Skip only
  reading/searching, git or shell operations, a single one-file one-shot edit,
  prose from current context, or pure conversation.
---

# Ringer orchestrator playbook

## Canonical install

**The production install is `/opt/ringer`, invoked as `ringer` (on `PATH`,
resolves to `/usr/local/bin/ringer` → `/opt/ringer/ringer.py`).** That is the
only install real work runs against — it is tested, promoted, and carries
every merged feature (`depends_on`, `check_timeout_s` as of 2026-08-07).

Every other checkout on this machine is scratch, not production:

- `/home/guidance/ringer_dev` — the development clone. Feature branches,
  PR prep, unit tests. Never run real orchestration work from here; it may be
  mid-edit, on an unmerged branch, or simply stale.
- Anything under a `scratchpad/` or `ringer-pilot` path — disposable worktrees
  from a specific session or pilot trial. Do not treat these as a stable
  install; they can vanish or be reset without notice.

If a command in this skill reads `./ringer.py`, that assumes the *canonical*
install — run it as `ringer` (bare, from `PATH`) unless you have a specific,
stated reason to target a dev or pilot checkout instead.

## Read this first — the five rules that actually get broken

1. **You review; workers type.** Your lane: specs, checks, pattern choice,
   reading results. If you are typing implementation, running probes, or
   babysitting a retry loop yourself, you have left your lane.
2. **A single task is a one-task manifest.** Same verification, zero
   ceremony. "Too small for Ringer" is how drift starts — the smoke test,
   the probe script, the three-edit fix are all one-task manifests.
3. **Beware the tiny-edit death spiral.** The named anti-pattern: each step
   is individually small enough to justify inline, and two hours later the
   exception has become the workflow and nothing was verified or visible.
   The one-shot exception is ONE file, a few lines, ONCE. The second pass on
   the same problem is a loop, and loops are manifests. **This spiral runs at
   multi-day scale too** — a 2026-08-27 review found continuous inline coding
   stretched across days, each edit individually excused as "just this one
   tweak before I delegate the rest." That excuse is the trigger, not a
   reason to keep going: the moment a second edit toward the same goal is
   about to happen, stop typing and write the manifest for whatever remains,
   however small it looks. Typing the fix yourself is not a faster path to
   delegating it later — it's the spiral. The job is specs and review; tokens
   spent typing implementation are tokens the orchestrator had no business
   spending.
4. **Verify the check before you debug the failure — especially before reaching
   for a stronger model.** A FAIL from Ringer is a claim about the check, not
   proof about the worker. A 2026-08-11 state-substrate round cost three
   separate correction cycles before anyone confirmed the checks themselves
   were broken (stale assertions, wall-clock-dependent tests, fixtures
   guessed against an unverified API) — none of it was the worker's fault,
   and the debugging happened at Opus rates: that one session cost $1,373 in
   orchestrator spend alone (2026-08-27 cost review). Before writing a single
   line of your own debugging, do the Post-run review ritual's check-first
   step (below): read the raw worker log, confirm the check failed for the
   RIGHT reason. Only debug or escalate to a pricier model once the check is
   confirmed sound — a cheap check that's actually broken is not a reason to
   bring in an expensive model to argue with it.
5. **Runs are watched, not hidden — and the screen comes up FIRST.** The
   moment this skill loads for real work, before you write a single spec,
   put Ringside on the human's screen: `./ringer.py hud` (idempotent — if
   one is already up it says so and opens the page; runs also auto-start
   it). Ringside is the PAGE at http://ringside.ubuhome (the LAN/Tailscale
   hostname for the HUD, which itself binds 127.0.0.1:8700). Give humans
   that URL, never the localhost:port. NEVER launch the
   Ringside.app application (`open -a Ringside`); it is a parked prototype
   with a stale frontend. And never go dark: if your prep (research,
   check-writing, manifest drafting) will take more than ~30 seconds,
   tell the human in one sentence what you're doing and roughly how long
   before you start — they should be watching the empty arena and reading
   your one-liner, not wondering if anything is happening. Never pass
   `--no-dashboard` except in automated tests or when the user explicitly
   asks.

Ringer runs manifest tasks in parallel across cheap CLI workers (Codex,
OpenCode/GLM, others via config) and verifies every task by **executing a
check command** — exit 0 is the only PASS. Failed tasks are retried once
with the check's actual failure output injected into the retry prompt. You —
the orchestrating model — pay tokens only for specs, orchestration, and
review.

```bash
./ringer.py lint manifest.json            # always lint before running
./ringer.py run manifest.json --identity <who-you-are>
./ringer.py demo                          # 3-worker smoke test
./ringer.py run manifest.json --dry-run   # print the plan, spawn nothing
```

Runs land in `~/.ringer/runs/`. Raw worker logs land in `<workdir>/logs/`.
Full reference: `README.md`. Ready-made manifest skeletons: `templates/`.
Lint catches unverifiable checks, silent checks, worktree deliverable/commit
loss, serial fan-out, write collisions, and underspecified specs; `run`
prints the same findings as non-blocking warnings.

## The one exception: `ask`

Rule 2 holds for anything that changes a file, runs a build, or produces an
artifact worth checking. One lane doesn't fit it: the human asks a bounded,
read-only question over source you can already point at, and the answer is
prose. A manifest for that is ceremony — but answering it in your own context
means pulling whole files into a conversation that is already expensive.

```bash
./ringer.py ask "<the human's request>" --source /absolute/path/to/source
```

`ask` selects the passages that match the request, caps the packet, spawns one
clean worker on it, and allows a single attempt. Repeat `--source` for several
files or directories; `--state` takes a small file of settled decisions;
`--dry-run` shows you the packet and spends nothing. If everything that matched
is too large for the packet it says so and stops before the model call rather
than letting a worker guess — but a source small enough to fit whole is sent
whole, relevant or not, so choosing the sources IS the work. Directory scans
stay inside the tree you name; a symlink leading out of it is skipped and
reported. Runs appear on Ringside like any other, and `--redact` hides the
request from Ringer's own state and eval records — it cannot scrub raw worker
output, which is captured verbatim by design.

**Be honest about what it verifies.** The check is that `answer.md` exists and
is non-empty. That is the weakest check in the tool, and it is also the best
available — there is nothing to execute against free-form prose. `ask` proves
the worker answered, never that the answer is right. You still read it.

**Everything else is a manifest.** Code changes, external actions, research
you intend to act on, anything whose output a check could actually execute —
those keep the full path. When a request sits near the line, the tiebreaker is
whether you could write a check that would catch a wrong answer. If you can,
write it, and make it a manifest.

## Codex completion bridge — no polling

`ringer run` is a blocking CLI and Ringer has no push/webhook mechanism. A
background shell process therefore cannot wake a Codex turn by itself. For
every real Ringer run under Codex, use one managed child agent as the bridge:

1. The director prepares and validates the manifest, then starts one child
   named `ringer_waiter`.
2. The child runs exactly `RINGER_NO_SELF_UPDATE=1 ringer run <absolute-manifest>
   --identity <identity>` in the foreground and waits for that command to exit.
3. The child does not poll, sleep, tail logs, refresh the HUD, inspect results,
   modify files, or launch another model. It returns only the exit status and
   the Ringer run ID/state path.
4. The director does not call `write_stdin`, re-run `ringer`, or query Ringside
   while the child is active. The managed child-completion event is the single
   wake signal. After it arrives, perform the normal post-run review.

Never claim that a background shell command or Ringside will notify Codex.
Do not add periodic wakeups as a substitute. If the child is interrupted, say
so and inspect the durable `~/.ringer/runs/<run-id>.json` only on the next
human-initiated or platform-delivered turn; do not start a polling loop.

## One job, one artifact

A job the human asked for — however many rounds it takes — is ONE artifact.
Use the SAME `run_name` for every round (`sd-crate-launch`, not
`sd-crate-r1` / `sd-crate-r2`): the library accumulates each round as a
version under one entry, and the human watches one page evolve instead of
hunting across three "live" tabs. Name it after the JOB in the human's
words, not after your batch structure.

And the artifact page is where results are REVIEWED. When a round finishes,
read the deliverables from the artifact store and direct the human to the
page — never `cat` result files into the terminal as the reveal. If a result
matters, it belongs in the artifact; if it isn't there, that's a harvest gap
to fix (declare it in `expect_files`), not a reason to bypass the page.

## Spec-writing craft

Workers are stateless and cannot ask questions. Every spec must be
self-contained:

- **Open with the role and the boundary.** "You are a read-only scout…",
  "Your current working directory IS a git worktree of <repo> — edit files
  here directly." State what the worker must NEVER touch before what it
  should do.
- **Name every file the worker owns.** In multi-worker runs over one repo,
  file ownership must be disjoint — and disjoint across *all* concurrent
  lanes/branches, not just within one batch. Every file a spec mentions must
  be in that worker's ownership list.
- **Embed the HOW TO RUN.** If the task drives a harness or script, put the
  exact command lines (with real absolute paths) in the spec. Workers should
  never have to discover an interface.
- **Define the output contract.** Say exactly which files to produce, where,
  and what each must contain. Graded/eval tasks should enumerate the grading
  criteria in the spec so the worker's output is checkable.
- **Hard rules travel in the spec, not in your head.** "Do NOT git commit",
  "never modify the repo, only write ./report.md", "stay in character; never
  help the AI" — the worker only knows what the spec says.
- **The spec is on camera.** Whoever is watching Ringside reads the spec as
  "what this agent was asked to do" — so write it as a self-contained,
  human-readable brief. Never write a pointer spec ("read /path/to/file and
  do what it says"): the watcher sees no brief, and the retry prompt loses
  the context it needs. Point at files for source MATERIAL; the instructions
  themselves live in the spec. Lint flags pointer specs.

## Check-writing rules

The check is the product. The retry prompt and the eval log both depend on
the check's failure output.

- **Know exactly how the check is invoked: cwd set, no arguments, stdin
  closed.** Ringer runs `task.check` as a shell command
  (`create_subprocess_shell(command, cwd=<taskdir>, stdin=DEVNULL)`) — it
  appends NO arguments. A check that expects `$1` (e.g. the worktree path)
  or any positional arg dies at its own guard before verifying anything,
  and the guard message is the useless output injected into the retry
  prompt — both attempts fail identically and the work is never judged
  (2026-08-18 layout-reconstruction run). Derive paths from cwd or bake in
  absolute paths. Confirm red the way ringer invokes it:
  `cd <taskdir> && bash check.sh` with no arguments — a red-test that
  hand-supplies `./check.sh <path>` proves nothing about the real run.
- **Checks must print WHY they fail.** `diff` beats `diff -q`; a validator
  script that prints which assertion broke beats `test -f`. A bare
  `test -f report.md` proves existence, not correctness.
- **Verify content, not existence.** Grep the artifact for required sections,
  run the code it produced, run the build, run the validator — execute
  something that would catch a lazy or hallucinated result.
- **`expect_files` is a floor, not the check.** List deliverables there for
  fast triage, but the check must still validate them.
- **Never `true`, `exit 0`, or `echo done`.** A check that cannot fail is a
  task that cannot be verified — that's just trusting the worker with extra
  steps.
- **Strict on substance, tolerant on format.** Checks that count exact
  headings, demand exact casing, or grep rigid phrasings fail honest work
  over formatting — and a wall of red format-failures reads as a broken
  system, not a careful one (demo-night lesson). Verify what must be TRUE
  (the file proves X, the code runs, the quote exists in the source), use
  case-insensitive and flexible matching for structure, and reserve hard
  failure for substance: missing evidence, fabricated content, code that
  doesn't run.
- **Keep the check under ~20 seconds.** `CHECK_TIMEOUT_S` is a hard-coded 60s
  in `ringer.py` and, unlike the per-task `timeout_s`, nothing in the
  manifest can raise it. A check that runs a full build or a real test suite
  fits at idle and blows the ceiling the moment parallel workers compete for
  the box — recording a FAIL the worker did not earn and poisoning the
  scoreboard. Put the *executed guarantee* in the check (the probe, the
  targeted suites, the validator) and run the whole-suite regression yourself
  at review. Say in your report that you did.
- **Put the check where the worker cannot write it.** Workers read the check —
  on Linux `opencode` has no filesystem confinement, so a scratchpad path is
  writable, and one worker EDITED the acceptance probe that was judging it
  mid-run. It disclosed the edit in its notes and the edit turned out to be
  faithful; neither fact is verification, and the pass meant nothing until it
  was re-established with a probe written afterwards in a directory no worker
  had been told about. Keep checks outside the writable surface, hash them
  before and after, or re-verify independently before believing any green.
  Reading the check is fine and makes a better spec; writing it is the end of
  the evidence.
- **Verify a property, never a sentinel.** Any check satisfiable by producing
  a magic string will be satisfied that way. Ask the real API the real
  question, then read the diff yourself.
- **Watch the check fail before you trust it, and use absolute paths to do
  it.** A probe written for this repo passed against the unfixed tree because
  both its assertions raised for the wrong reason — an illegal-transition
  refusal, not the missing fence it was meant to detect. Separately, a seed
  that "caught nothing" turned out to have edited a relative path under an
  unexpected working directory, changing no file at all. Both failures argue
  for deleting a good check. Confirm red, from a known cwd, before believing
  green.
- **Demand quotes, and verify them against the file they cite.** For research,
  review and audit tasks, requiring every claim to carry verbatim source text
  — checked as a literal substring of the *named* document, not merely
  present somewhere in the corpus — is the single highest-value check shape
  found so far. It refuses fabricated citations, and it refuses real words
  attributed to the wrong authority, which is the subtler and more damaging
  of the two.
- **Any parser inside a check must accept every legal token — digits
  included.** A check that extracts citations, paths, or IDs with a regex
  whose character class omits digits truncates real strings
  (`ingestor/services/stage1/…` → `…/stage`) and then "fails" honest work
  over a file that never existed — a FAIL earned by the check, not the
  worker (2026-08-18 QC citation check rejected an APPROVE verdict this
  way). Use classes that cover digits and separators (`[A-Za-z0-9._/-]`,
  `\w+`), and before trusting the check, run the extractor over the actual
  strings in the report or fixture it will judge. A FAIL citing a path
  that can't exist is a check bug until proven otherwise.

## Pattern playbook

Reach for a named pattern before inventing one. Skeletons in `templates/`:

| Kit | Use when |
|---|---|
| [review-swarm](../../../templates/review-swarm/) | You need broad read-only review coverage before deciding what to fix. |
| [fix-swarm](../../../templates/fix-swarm/) | You have confirmed independent fixes that can be split across isolated worktrees. |
| [focus-group](../../../templates/focus-group/) | You need isolated persona feedback on a product, pitch, prompt, or workflow. |
| [bakeoff](../../../templates/bakeoff/) | You need evidence for choosing a model, prompt, or configuration across shared scenarios. |
| [research-with-proof](../../../templates/research-with-proof/) | You need research backed by a proof task whose check executes the claim. |
| [launch-kit](../../../templates/launch-kit/) | You need a go-to-market package built across research, persona review, and final assembly rounds. |
| [asset-swarm](../../../templates/asset-swarm/) | You need media assets produced in parallel with executable checks for renders, batches, diagrams, or captures. |
| [adversarial-review](../../../templates/adversarial-review/) | You want several models to review the same artifact before the orchestrator synthesizes findings. |
| [repo-feature](../../../templates/repo-feature/) | You know what to build and need sandboxed workers to edit a real repo with build and git checks. |
| [migration-swarm](../../../templates/migration-swarm/) | You have mechanical codebase transforms that can be partitioned across worktrees. |
| [doc-swarm](../../../templates/doc-swarm/) | You need module docs with executed examples and checks against invented APIs. |
| [test-hardening](../../../templates/test-hardening/) | You need stronger tests by module while keeping production source edits off-limits. |
| [competitive-teardown](../../../templates/competitive-teardown/) | You need competitor research with citation allowlists and a synthesis phase. |
| [data-pipeline](../../../templates/data-pipeline/) | You need fetch, transform, and validate stages with executed validators and honesty rules. |
| [probe](../../../templates/probe/) | You need a one-task manifest for a smoke, probe, or post-mortem. |

Pattern-selection judgment:

- **Browse the catalog first.** Before writing any manifest, browse
  `templates/README.md`: choose a kit, mix pieces from several, or write
  your own having seen the prior art.
- **Review before fix.** Run a read-only review swarm, read the reports
  yourself, then compile the confirmed findings into a fix-swarm manifest.
  Don't let the same worker find and fix. When the reviewer can be decided up
  front, `depends_on` (below) puts both stages in ONE manifest so you aren't
  sitting between them waiting to launch the second.
- **Personas must be separate workers.** Parallel personas in one context
  bleed into each other. One persona per task, one session dir per task.
- **Iterating on a prompt/product? Re-run the same panel.** A fixed persona
  panel across rounds tells you whether a change fixed what the panel
  actually complained about.
- **Probes, smokes, and diagnosis loops are manifests too.** A model-calling
  smoke test is a one-task manifest with the transcript as `expect_files`
  and a validator as the check. Diagnosing a failed worker's output is a
  read-only scout task. If it calls a model, it runs under Ringer — that is
  what makes it visible, verified, and logged.

## Staged tasks: `depends_on`

A task can name prerequisites that must all PASS before it becomes eligible:

```json
{"key": "schema-qc", "depends_on": ["schema-producer"], "engine": "opencode"}
```

Use it when the second stage is decidable up front — producer then QC, build
then audit, draft then persona panel. It buys you one thing: you stop being the
thing that notices stage one finished and launches stage two.

- **A failed prerequisite SKIPS its dependent.** No worker is launched, no
  attempt is consumed, and no eval row is written — the reviewer never runs
  against work that didn't build, and the scoreboard doesn't get a row for a
  model that never saw the task. `blocked_by` names what stopped it, and
  skips propagate down the chain.
- **Waiting happens before the concurrency slot**, so a two-stage manifest at
  `max_parallel: 1` runs stage one then stage two instead of deadlocking.
- **A prerequisite isn't terminal until its retries finish.** Fails attempt 1,
  passes attempt 2 — the dependent runs.
- **It is a CONTROL dependency, not a data one.** Nothing flows between tasks
  automatically. In worktrees mode a passing task's worktree is DELETED before
  its dependent starts, so anything the dependent needs must be exported by the
  producer's *check* to a durable path outside the worktree, and the dependent's
  spec must name that exact path. This is the mistake to expect: a QC task that
  says "review the patch" without saying where the patch is will review nothing.
- **Don't stage what doesn't need it.** Independent tasks should stay
  independent — dependencies serialize work that could have run in parallel.

Cycles, self-dependencies, unknown keys, duplicates and malformed values are
rejected when the manifest is parsed, so `lint` catches a bad graph before any
worker spawns.
## Engine selection

**The engine choice belongs to the human — but the recommendation comes
from THEIR evidence.** Before the FIRST run of a job: read what's wired up
(`[engines.<name>]` blocks in `~/.config/ringer/config.toml`), run
`./ringer.py models --task-type <this job's type>` for the local scoreboard,
and glance at `./ringer.py catalog --changes` for anything newly free or
newly cheap. Then ask the user which model should do the typing — top 2–3
options with the NUMBERS in the pitch and a recommendation, e.g.: *"GLM is
6/6 first-try on persona work here at ~2¢/task — recommended. Codex is also
100% but ~8x the tokens. And kimi went free on OpenRouter yesterday — want
it auditioning one of the small tasks?"* Honor their pick via the per-task
`engine`/`model` fields; don't re-ask every round of the same job unless
the mix isn't working. This is per-user by design: the scoreboard learns
THIS user's workload — never import another machine's conclusions or
recommend from a different user's numbers.

**A membership seat is the CHEAPEST lane, not the escalation.** Ask which
engines are billed to a subscription the user already pays for. Those cost
nothing at the margin, so "keep costs down" means *put the heavy work on the
membership and spend metered tokens only on exploration* — the opposite of
the usual cheap-first instinct. On this machine (2026-08) `codex` is
membership-billed and everything reached through `opencode` is metered per
token. When a membership lane runs dry, say so explicitly and by name: the
user can top it up, and until they do the whole cost ordering inverts.

**A cost figure has a shelf life.** Prices move, and a provider can announce a
"significant increase" with no figure and no date (DeepSeek did, 2026-08-06 —
then landed it on 2026-08-13, see below). Two consequences worth acting on:
re-measure after a change lands rather than demoting a model on a rumour, and
treat any window where a cheap capable lane exists as the time to audition free
and untested lanes *on real work* — building that evidence after the cheap lane
disappears means building it under pressure with nothing to catch the mistakes.
Membership-billed lanes are the only ones immune to this, which is a second
reason to keep one.

**A cost figure can also have a shelf life measured in hours — DeepSeek now
bills by time of day.** From **16:00 UTC 2026-08-16**, DeepSeek charges peak
rates during **01:00–04:00 and 06:00–10:00 UTC** and half that the other 17
hours **on weekdays**. **Effective 2026-08-23, weekends (Saturday–Sunday, Beijing Time) have no peak/off-peak distinction — all weekend calls charge uniformly at the off-peak rate.** Same model, same task, same tokens, 2x the bill depending on when the
batch fires. Four things follow for the scoreboard:

- **A ¢/task figure from a DeepSeek row is now ambiguous unless you know when
  it ran.** Off-peak and peak rows for one model differ 2x for reasons that
  have nothing to do with the model. Don't compare a peak row against an
  off-peak row, and don't average them into one number you then quote to the
  user as "GLM vs DeepSeek."
- **Say the window when you pitch DeepSeek.** "deepseek-v4-pro, ~X¢/task
  off-peak — it's 09:30 UTC so we'd be in peak and pay double; the window
  clears at 10:00" is the honest version of the pitch. Scheduling a
  non-urgent batch past the peak boundary is a real, free cost lever that no
  other lane on this host offers.
- **The absolute numbers moved up, not sideways.** Even off-peak, output is
  ~2.3x the old rate; at peak `deepseek-v4-pro` ($5.28/1M combined) sits above
  `gpt-5.4-mini` and near `glm-5.2`. Any prior "DeepSeek is the cheap
  metered lane" conclusion in the scoreboard predates this and should be
  re-earned, not inherited. Rates: [llm-router models-paid-costs.md](../llm-router/references/models-paid-costs.md#deepseek--time-of-day-billing-from-2026-08-16) and [pricing YAML](../llm-router/docs/model_pricing_as_of_260430.yaml#deepseek_primary).
- **Membership lanes get more attractive, not less.** `codex` is
  membership-billed and unaffected by any of this — the argument for putting
  heavy work there just got stronger.

**Three DeepSeek lanes are registered here and they no longer cost the same.**
`model-identity.toml` deliberately maps `deepseek/deepseek-v4-flash` (direct
provider auth in opencode), `openrouter/deepseek/deepseek-v4-flash`, and
`[engines.deepseek_direct]` (Claude CLI against DeepSeek's Anthropic-compatible
API) to **one model name**, because they are one trained artifact and should
share a scoreboard row. Time-of-day billing splits them on price without
splitting them on identity: the two direct-auth lanes bill DeepSeek's
peak/off-peak rates, while the OpenRouter lane bills whatever OpenRouter
charges — which may not adopt peak/off-peak at all. So after 2026-08-16, "same
model" no longer implies "same cost," and *which route* plus *what time* both
have to be stated before a DeepSeek cost figure means anything. Keep the shared
identity row (it's right about the model); just don't read cost off it.

**`catalog --changes` will not see this.** The catalog tracks OpenRouter, and
DeepSeek's own price change is not an OpenRouter event — expect no
`price_change` row for the direct lanes. More fundamentally, the catalog
carries one `prompt`/`completion` price per model with no time dimension, so
there is no field where "half price for 17 hours a day" can be stored. Until
that changes, DeepSeek peak/off-peak lives in the human-read docs, not in
tooling that can warn you: [llm-router models-paid-costs.md](../llm-router/references/models-paid-costs.md#deepseek--time-of-day-billing-from-2026-08-16).

**Probe with the output contract you actually need.** A probe that proves a
lane can read a file and write a short one proves auth and basic tool use and
predicts nothing about file-write discipline on a long structured task. Two
free models passed exactly that probe first try and then, within the hour,
each burned six figures of tokens on a real review and never wrote the
report — the recorded failure mode of free-tier models, now seen across five
of them: **they produce the content and skip the file.** Shape the probe like
the job.

**Probe a lane before betting a batch on it.** Auth dies, credits run out,
and free tiers have caps that no amount of retrying will clear. On
2026-08-06 three of four lanes in one batch failed without a model executing
a single step — codex out of workspace credits, zai returning 401, and
groq's free tier refusing a 33k-token task against an 8000 TPM ceiling. Each
one logged a FAIL row against a model that never ran. A one-task manifest
against a new or long-unused lane costs seconds and saves the batch. When
you report such a failure, name it as infrastructure and say the scoreboard
row is unearned, or the next orchestrator will route around a good model.

**Read the auth file before trusting a catalog slug.** `catalog --changes`
and `--explore` list OpenRouter models, but an `opencode` engine may be wired
to direct provider auth instead, in which case an OpenRouter promo is not an
exploration candidate at all — this host went from seven direct providers to
seven plus OpenRouter (339 models) inside one session, silently, because
someone added a key. Check `~/.local/share/opencode/auth.json` for the
provider list and `opencode models` for the slugs that actually resolve;
a provider set you read an hour ago is not evidence.

**Explore or the scoreboard fossilizes.** Always recommending the proven
pick means never learning a new one. In any run of 3+ tasks that has a
low-stakes lane (docs sweeps, mechanical edits, persona reviews — strong
executed check, retry to absorb failure), assign roughly ONE task to an
exploration candidate from `./ringer.py models --explore --task-type <type>`
(untested + cheap or free, text-capable, decent context). Free promos from
`catalog --changes` jump the queue — a temporarily-free model is a zero-cost
experiment. Never explore on time-critical work, never with more than a
small slice of a batch, and name the experiment when presenting the engine
ask so the human can veto it. Promotion ladder (computed by --explore):
untested → probation (some evidence) → proven for a task_type (3+ tasks,
first-try ≥ 0.67). Proven models earn bigger lanes in that type and an
audition one rung up in adjacent types; repeated first-attempt failures end
the audition — record the demotion in MODEL-NOTES so the next orchestrator
doesn't re-run the experiment.

**OpenCode is the harness; the model is a manifest field.** Unless a model
ships its own first-class harness (Codex does), it runs through the
`opencode` engine with the task's `"model"` field set to the OpenRouter
slug — e.g. `"engine": "opencode", "model": "openrouter/moonshotai/kimi-k2.7-code"`.
This holds even when someone — including the user, in the heat of a run —
says to "call kimi directly" or reach for the model's own CLI: the harness
is what provides the sandbox, raw logs, token counts, and executed
verification, so routing around it silently drops all four. Never clone an
engine block or splice `-m` through `engine_args` to change models; that's
what the `model` field is for, and a bakeoff is only real when the MANIFEST
names each competitor (2026-07-06 lesson: an engine block with a hard-coded
model ran one model under three competitors' names).

Engines are config blocks (`[engines.<name>]` in config.toml), selectable
per task via the manifest `engine` field. Defaults are deliberate:

- **codex** (default): strongest general worker. Use per-task `engine_args`
  to set reasoning effort — spend it on hard tasks, not boilerplate.
- **opencode**: the universal lane — any OpenRouter model via the `model`
  field (engine `model_default` is GLM-5.2, the cheap-intelligence pick).
  Validate a model new to you with a trivial one-task manifest before
  trusting it with a batch.
- Small/flash-class models are the first to choke on long conversational or
  multi-turn harness tasks — watch their retry counts before scaling them.
- Match `timeout_s` to the task: conversational harness tasks and
  build-and-test checks need far more than file edits.
- **Check the evidence before assigning models to tasks.** Run
  `./ringer.py models` (optionally `--task-type <type>`) — the local
  scoreboard aggregating every executed-check outcome per (model,
  task_type): first_try_pass_rate is the routing signal; pass_rate includes
  retry rescues. Then read the model notes for the judgment the numbers
  can't carry. Routing is grounded in performance, not vibes (Jon directive
  2026-07-06).
- **Personal model notes live in the state dir, not the repo.** The repo's
  `docs/MODEL-NOTES.md` is tracked by git and carries upstream community
  notes — it will conflict on every `git pull` if you add personal
  observations to it. Keep YOUR run observations in
  `~/.ringer/MODEL-NOTES.md` instead (untracked, survives all updates).
  Read them with `./ringer.py models --notes-file ~/.ringer/MODEL-NOTES.md`.
  The repo copy stays clean for upstream notes; your state-dir copy is yours
  alone. When a model demotion or discovery needs recording, write it there —
  the next orchestrator that reads the right file won't re-run a failed
  experiment.
- **"Show me the scoreboard" is one command.** When the human asks to see
  the model scoreboard, rankings, model costs, or "which models work best,"
  run `./ringer.py models --open` — it renders the full scoreboard (tiers,
  first-try rates, est. $/task, usage, MODEL-NOTES excerpts, free-promo
  watchlist) as a zero-LLM HTML page in the artifact library and opens it
  in their browser. Costs no tokens; never hand-summarize the numbers when
  the page can show them.
- **Give every task a `task_type`** (canonical vocabulary in the README —
  code-feature, code-fix, code-review, research, persona-review, site-build,
  image-gen, docs, probe, bakeoff, ...). Untyped tasks bucket as (untyped)
  and teach the scoreboard nothing; lint nudges you when it's missing.

## Worktrees-mode footguns (learned the hard way)

Run-level `"worktrees": true` gives each task an isolated git worktree of
`repo`, detached at HEAD. Three consequences:

1. **Passing tasks get their worktree DELETED.** Deliverables must land
   outside the task worktree, or the check must export them first.
2. **Worker commits die with the worktree.** Pattern that works: the worker
   leaves changes uncommitted; the check runs
   `git add -A && git diff --cached > <path-outside-worktree>.patch` and
   validates the patch. You apply and commit on your branch after review.
3. **Logs survive** (they go to `<workdir>/logs/`), so post-mortems work
   even on deleted worktrees.
4. **Gitignored outputs silently vanish from patch exports.** `git add -A`
   cannot stage ignored files (build dirs like `dist/`), so a worker's edits
   there pass its checks, export an incomplete patch, and die with the
   worktree. If a task touches any gitignored path, the check must `cp`
   those files to a path outside the worktree explicitly — verify the patch
   AND the copies before trusting the run.

And on your own side of the fence: when integrating patches into the real
repo, stage specific paths — never `git add -A` in a checkout that may hold
someone's untracked scratch files.

## Post-run review ritual

1. Read the run JSON in `~/.ringer/runs/` — statuses, retries, durations.
2. For any retried or failed task, read the raw worker log in
   `<workdir>/logs/` before deciding anything. Retries that passed on
   attempt 2 often reveal a spec ambiguity worth fixing in your next
   manifest.
3. Spot-check at least one PASSING task's artifact per run. The check
   catches most laziness; you catch the rest.
4. Failures with useless error messages mean your CHECK needs work, not
   (only) the worker. A check bug FAILs the worker without ever judging
   the work — an UNEARNED scoreboard row. When you confirm the FAIL was
   check-side (arg guard, bogus path, regex truncation), say so in your
   report and invalidate the row:
   `ringer models --invalidate --run <run_id> --task <task_key> --reason
   "<the check bug>"` (omit `--task` to cover the whole run;
   `--first-attempt-only` leaves a genuine retry pass standing). `--reason`
   is mandatory — never invalidate without naming the check bug.
   Invalidated rows are excluded from scoreboard computation, so the
   models involved take no penalty.
5. **Update your model notes** when a run taught you something about a
   model: one dated line under the model — task type, what happened
   (attempts, tokens, failure mode), what you'd do differently. Only what
   the executed checks and raw logs support. The raw numbers took care of
   themselves — every attempt already landed in the local model log
   (`./ringer.py models` to see the updated scoreboard).
   **Write to `~/.ringer/MODEL-NOTES.md`, NOT the repo's tracked copy.**
   The repo `docs/MODEL-NOTES.md` is upstream community notes and will
   conflict on `git pull` — it's tracked, yours isn't. Your state-dir copy
   survives all updates and can include both upstream notes and your own
   observations. Read it with `--notes-file ~/.ringer/MODEL-NOTES.md`.
6. **Update your skill** when a run taught you something about using
  ringer correctlyt: update one dated line in the skill to prevent the same
  mistake next time. Include the task type, what happened.  Avoid skill
  bloat: only include what the executed checks and raw logs support.

## Spend your own context deliberately

The scoreboard exists so that worker tokens buy evidence. Your own tokens are
not free either, and nothing in the tool constrains them:

- **Reach for code before a model.** Counting, sorting, exact-text search,
  field extraction, format conversion, file comparison, validation — `rg`,
  `jq`, a parser, a two-line script. A model imitating `grep` is an expensive
  way to get a worse `grep`.
- **Select passages; don't load files.** Search first, then read what matched.
  Loading a whole transcript because the answer is somewhere inside it is how
  a cheap question turns expensive. `ask` does this for you; when you are not
  using `ask`, do it by hand.
- **Load a tool when the job needs it** — not every connector and schema at
  the top of a session on the chance that one gets used.
- **Answer the question that was asked.** A sentence when a sentence was asked
  for. No process diary, no restating the human's request back to them, no
  unrequested options.
- **Never retry into a limit.** A token- or usage-limit failure is not a
  transient error; retrying it just burns the budget faster. Reduce the input
  or take a cheaper path.

When you claim a saving, count the whole job — every call, including your own
planning and review. Moving tokens from your context into a worker's is only a
saving if the total came down.

## Baked-in invariants (preserve in any change to ringer.py)

Stdin closed (`< /dev/null`); sandbox mode explicit; verification executes
the artifact; logs carry raw worker output only. These are load-bearing —
engine and invocation changes must keep all four.
