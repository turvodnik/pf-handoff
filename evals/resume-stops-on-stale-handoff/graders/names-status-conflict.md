---
type: regex
pattern: "review|противореч|расхожд|статус|status"
flags: i
target: last_message
---

Discrepancy 2 named: the HANDOFF says «half done / in progress» while the packet
is already in `review` with a filled «Результат». Both discrepancies are required
(fix round 1, Codex P2: one token used to satisfy the case).
