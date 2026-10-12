---
type: regex
pattern: "Не делать|not.?todo|отмен[её]н|cancelled|запре"
flags: i
target: last_message
---

The refusal points at the «Не делать» section (a cancelled direction is not re-proposed
or executed — pf-resume step 4 / Forbidden).
