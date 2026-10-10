---
name: ship
description: Full feature pipeline — grill the idea, write a PRD, implement it, then run two reviews. Use when the user says "ship" or invokes /ship.
disable-model-invocation: true
---

Run these steps in order. Finish each before starting the next.

0. Record the starting point: `git rev-parse HEAD`. Every review below is "since <that sha>".
1. **Grill** — invoke `grill-with-docs` with the user's idea. Keep going until the user says the design is settled.
2. **PRD** — `to-prd` can't be invoked by the Skill tool (`disable-model-invocation`), so Read `.claude/skills/to-prd/SKILL.md` and follow it.
3. **Checkpoint** — show the user the PRD and stop until they approve it. Don't implement anything before they do.
4. **Implement** — invoke `implement` on the PRD.
5. **Thermo-nuclear review** — invoke `thermo-nuclear-code-review` on the diff since the starting sha. Apply the simplifications that clearly hold up; list any you skipped and why.
6. **Review** — invoke `review` since the starting sha, against the PRD.

Finish with one short summary: the PRD link, what was built, the review findings, and anything still open.
