---
name: effect-reference
description: Locate and assess frozen Effect references before porting behavior.
---

# effect-reference

Read manifest and INDEX; select exact source, test and docs paths. Check version and integrity with python3 tool/reference_snapshot.py verify. Compare docs revision to source release; source is authoritative. Cite local evidence paths and status. Do not fetch automatically; record precise missing evidence. Output behavioral notes and mismatches, not claims based on summaries alone.

References resolve from the repository root; material stays in references/effect, outside this skill.

The upstream reference pack and Node comparison tooling are local-only and Git-ignored
by user instruction. If absent in a clone, use the committed architecture/contracts
and Dart tests; report exact reference gaps and never fetch automatically.
