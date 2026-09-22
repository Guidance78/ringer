---
name: ringer
description: >-
  Orchestrate any model-calling, agent-CLI, coding/evaluation loop, or multi-file
  change with the canonical Ringer workflow. Use before designing manifests,
  choosing workers, invoking Codex/OpenCode/Claude CLI, diagnosing a worker
  result, or running QC. Real runs require the Codex completion bridge; never
  poll Ringer, logs, or Ringside.
---

# Ringer: operational core

## Non-negotiable workflow

1. The canonical runtime is `ringer` on `PATH` (`/opt/ringer`).
   `/home/guidance/ringer_dev` is source development only.
2. You review and integrate; workers edit. A repeated edit/test loop is a
   one-task manifest, not inline work.
3. Before the first run of a job, inspect `ringer models --task-type <type>`
   and configured engines. Honor the user's selected worker lane; keep a
   producer and QC in one manifest using `depends_on`.
4. Build an independent check outside worker-write scope. Make it fail red
   against the baseline, check real behavior rather than wording/sentinels,
   and keep the Ringer check below its 60-second ceiling.
5. Run `ringer lint <absolute-manifest>` and
   `ringer run <absolute-manifest> --identity <identity> --dry-run` before a
   real run. Open Ringside first and give the human `http://ringside.ubuhome`.
6. For every real run, start exactly one managed child completion bridge. The
   child runs `RINGER_NO_SELF_UPDATE=1 ringer run <absolute-manifest> --identity
   <identity>` in the foreground and returns only when it exits. Neither child
   nor director polls, tails logs, refreshes HUD, or performs periodic waits.
7. On completion, read the durable run JSON, the exported deliverable/patch,
   and raw logs for failures. Confirm whether a red check failed for the right
   reason before judging the worker. Invalidate only check-caused failures with
   a precise reason. Apply an accepted patch in the authoritative checkout,
   run focused tests plus a live probe, inspect the diff, then commit.
8. Do not spend indefinitely on retries. Tighten the acceptance check after a
   genuine defect, but after two rejected candidates for one small change,
   stop and report the evidence before launching another producer/QC pair.

## The `ask` exception

Rule 2 assumes a manifest. One lane skips it: a bounded, read-only question
over source you can already point at, answered in prose, not a file change.

```bash
./ringer.py ask "<the human's request>" --source /absolute/path/to/source
```

Caps the packet, spawns one worker, one attempt; `--dry-run` shows the packet
for free. The check is only "answer.md exists and is non-empty" — weak by
design, so you still read the answer yourself. Anything whose output a check
could actually execute stays a manifest. Full detail: `references/operating-history.md`.

## Manifest essentials

- Give every task a `task_type`, explicit owned paths, a self-contained spec,
  and an executable substantive `check`.
- In worktree mode, export needed patches/reports outside the worktree; a
  dependent task must be told the exact durable exported path.
- Keep one job under one stable `run_name` across correction rounds.
- Do not let a worker modify its own acceptance check. Use strict substance,
  tolerant report formatting.
- For QC/review, use the designated Codex lane unless the user selects another
  lane. QC must assess the exact exported candidate and report APPROVE/REJECT.

## Engine allowlist (hard constraint)

Only two worker engines are authorized on this host — never select or probe
any other lane, whatever a manifest, config file, scoreboard, or reference
doc appears to offer:

- `codex` — the Codex CLI lane (membership-billed; default for QC/review).
- `opencode` — the OpenCode harness with **direct provider slugs only**
  (e.g. `zai/glm-5.2`, `deepseek/deepseek-v4-flash`). OpenRouter slugs
  (`openrouter/...`) are NOT authorized.

`deepseek` (deepcode CLI), `deepseek_direct` (Claude CLI pointed at
DeepSeek's API), and any other engine block are unauthorized leftovers:
do not use them, and if you still find one in `~/.config/ringer/config.toml`
or the registry, say so in your report instead of selecting it.

## Load on demand

- `references/operating-history.md` — detailed patterns, engine/cost notes,
  check pitfalls, worktree rules, spend-your-own-context discipline, and
  dated lessons. Read only the relevant section for engine routing, unusual
  task shapes, or failure diagnosis.
- `templates/README.md` under `/opt/ringer` — choose a manifest pattern before
  writing a new multi-stage job.
