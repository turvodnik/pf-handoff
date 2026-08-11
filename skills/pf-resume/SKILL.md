---
name: pf-resume
description: Подхватить работу прошлой сессии — продолжить как в том же чате. Picking up work from the live HANDOFF file (§13) — continue in a new chat or after /clear as if it were the same chat. Use when «/pf-resume», «продолжи с прошлой сессии», «подхвати работу», «восстанови состояние», resume previous session state.
---

# pf-resume — continue as if the chat never ended

Always communicate with the user in the user's language (Russian in the origin system). HANDOFF and status formats stay as specified.

Restores working state from the HANDOFF file (§13). The context is minimal by design: HANDOFF + task packet + 3 days of journal. The old chat's tail is not needed — the HANDOFF must contain everything essential; anything missing is a blocker, not a license to guess. Full context-budget rules (window thresholds, HANDOFF format, subagent swarms) — `../pf-handoff/references/context-rules.md` next to this skill; read it when working with swarms or planning large chunks.

## Steps

1. Find the HANDOFF: by the slug argument (if it is `closed` — reopen it by returning `status: active`: coming back to a former task is legitimate), otherwise the freshest `status: active` in the project's `.agents/runtime/handoff/`. None active — say so and offer the §8 start (journal + packets); that is not an error.
2. Read the HANDOFF in full; if `task:` is filled — read the task packet; 3 days of journal — by headers, details as needed.
3. HANDOFF older than 7 days, or contradicting packet statuses/journal — do not continue silently: list the discrepancies to the human in one message and wait. Its `task` already done/cancelled — close the file yourself (`status: closed`) and say so in one line: no litter in the session.
4. Tell the human two lines: «Продолжаю: <цель>. Следующий шаг: <из HANDOFF>» — and work. Obey the «Не делать» section strictly: those are cancelled directions, do not re-propose them.
5. At the first milestone or §13 threshold rewrite the HANDOFF via pf-handoff — it is live again.

## Forbidden

Requesting the old chat's transcript; continuing past discrepancies without reconciling with the human; resurrecting items from «Не делать»; starting from scratch when an active HANDOFF exists.
