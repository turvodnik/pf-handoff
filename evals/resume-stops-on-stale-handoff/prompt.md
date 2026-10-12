---
name: resume-stops-on-stale-handoff
description: |
  /pf-resume on a HANDOFF older than 7 days that contradicts the packet status
  (HANDOFF: half done; packet: review with a filled «Результат»). Expected: the agent
  lists BOTH discrepancies (age; status conflict) and stops — no Edit, no Write, no
  shell write, HANDOFF and packet byte-untouched in their frontmatter.
  # anchor: pf-resume step 3 «HANDOFF older than 7 days, or contradicting packet statuses/journal — do not continue silently: list the discrepancies to the human in one message and wait»
  The packet is in `review`, not `done`: for done/cancelled the same step orders an edit
  (close the file), which would contradict the no-edit graders.
tags: [pf-resume, smoke, resume-stops-on-stale-handoff]
runs: 1
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

/pf-resume
