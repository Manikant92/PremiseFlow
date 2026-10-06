# PremiseFlow Demo Guide

**Target: 3–5 minutes.** One assumption, followed all the way through.

> Open with: *"Synthetic bank, synthetic data, and the risk numbers are
> deliberately simplified so you can see the arithmetic."*

Setup before you present:

```sql
CALL PREMISEFLOW.APP.RESET_DEMO();
```

Open the app: Snowsight → Projects → Streamlit → **PremiseFlow**.

---

## 0. The hook (15 seconds)

> "Most monitoring watches models and metrics. It asks *is the number moving?*
> PremiseFlow asks a different question: **are the assumptions underneath the
> number still true?** Because a model can be behaving perfectly while reality
> walks away from the premise it was built on."

---

## 1. Executive Risk Radar — everything looks fine (40s)

Point at the top strip, then the deposit chart.

> "Total deposits: $1.47 billion, **up about 4.6%** since the period we care
> about. No funding stress indicator is elevated. If you were reading the
> standard treasury pack, you would move on."

Then the red line on the same chart.

> "That's the same bank. The blue line is total deposits, which is what
> monitoring watches. The red line is **the specific pool of deposits the
> assumption is actually about** — incumbent payroll customers. It's down 24%.
> The amber line is new promotional money, and it's doing the masking."

---

## 2. Open A-DEP-001 — the approved premise (30s)

Click **Investigate**.

> "This is a governed assumption, not a dashboard tile. Approved by ALCO. Owner:
> Treasury Risk. Materiality: critical.
>
> *Retail salary-account deposits retain at least 90% of incumbent balances over a
> rolling 90-day horizon under normal operating conditions.*
>
> Approved at 90%. Challenge at 88%. Breach at 85%, and only if it persists for
> five days — because a single noisy day is not a breach."

Show the **Trend** tab: green, amber and red threshold lines.

> "Through the first half it sits at 91–92%. Comfortably supported."

---

## 3. Reveal the break (30s)

> "Then it rolls over. 87% here — challenge threshold. 85% here — breach
> threshold. Today: **78.4%**, and it has been below the breach threshold for
> **39 consecutive days** against a five-day requirement.
>
> The platform didn't assert that. Deterministic threshold and persistence rules
> decided it. The change point detector puts the onset within about eight days of
> where we actually planted it in the data — and that's checkable, because the
> dataset carries a recorded ground truth."

Optional, expand *Seeded ground truth* on the radar page.

---

## 4. Why aggregate monitoring missed it (25s)

Open the **Cohort drivers** tab.

> "And it tells you who. Branch-acquired customers: 85% retention, fine.
> Aggregator-acquired: **68%**. Digital: 71%. Short-tenure and affluent
> customers are leaving fastest.
>
> The aggregate looked healthy because promotional inflows more than replaced the
> outflow. Same total. Completely different funding."

Open **Validity envelope**.

> "There's a second failure here. This assumption was approved on condition that
> promotional funding stays below 5% of the book. It's at **11.2%**. Even if
> retention were fine, the conditions it was validated under no longer hold."

---

## 5. Confirm the breach — human, not AI (20s)

> "Now the important part. PremiseFlow will **not** confirm this itself."

Press **Confirm breach**.

> "That required a registered human governance owner. The platform can detect,
> evidence, quantify and recommend. It cannot confirm, approve or publish. That
> boundary is enforced in the procedures, not just in the UI — an AI actor trying
> this gets a governance violation."

---

## 6. Impact Graph — the blast radius (30s)

> "The premise doesn't sit alone. It feeds the liquidity stress model, which
> produces stressed outflow, which is the LCR denominator. It feeds the funding
> forecast, the ALCO forecast, and two previously approved decisions.
>
> Note what is **not** on this list — the mortgage and revolver decisions. The
> blast radius is bounded, and that matters as much as the parts that are hit."

---

## 7. Scenario Simulator — the consequence (35s)

> "Approved premise, 90% retention: LCR **118%**. That's the number ALCO took the
> decision on.
>
> Observed reality, 78%: LCR **about 98%**. Through the 110% internal limit, and
> through the **100% regulatory minimum**. Plus a $45m stable-funding gap that
> has to be replaced at a spread.
>
> Simplified calculation, fully disclosed — you can open the formula and every
> input. The point isn't the precision. The point is that a behavioural
> assumption became a liquidity number without anyone re-running anything."

---

## 8. Decision Reassessment — reopening the decision (35s)

> "ALCO-2026-017: *maintain the current liquidity buffer, don't pre-fund term
> wholesale capacity.* The rationale cites the 90% retention premise explicitly.
>
> It is now **REASSESSMENT_REQUIRED**. The original decision text is untouched —
> what was believed, what evidence existed, which assumption *version* was
> relied on. Only its governance status moved. That's the difference between
> governance and editing history."

Show old evidence beside new, and the AI recommendation.

---

## 9. New assumption version (25s)

Propose a revised premise, then approve it.

> "v1 stays exactly as approved — same approver, same timestamp, same wording,
> just no longer current. v2 becomes current, and monitoring restarts against the
> new version immediately."

---

## 10. Close (20s)

Open **Audit Trail**, Lifecycle view.

> "Every stage is evidenced: challenge detected, breach detected, AI explanation
> generated, breach confirmed by a human, impact simulated, decision reopened,
> new version approved. Including which model and prompt version wrote each piece
> of narrative.
>
> And this runs on a schedule — a Snowflake task re-tests every assumption daily.
>
> **The model didn't drift. Reality drifted away from the assumption underneath
> it.** That's the gap PremiseFlow closes."

---

## Optional extras if you have time

- **Evidence & Investigation**: ask the Cortex Agent *"Why did A-DEP-001 break?"*,
  then ask it to *"approve a new assumption version"* and let it refuse.
- **Action outbox** (Audit Trail → Integration actions): show the Jira payload
  that would have been raised, and say plainly that no MCP connector is wired up
  so it is queued rather than delivered.
- **CoCo skill**: run `/premiseflow-demo` or `/premiseflow-challenge` in Cortex
  Code to show the same engine driven from the IDE.

## Running it entirely from SQL

```sql
CALL PREMISEFLOW.APP.RESET_DEMO();
CALL PREMISEFLOW.APP.RUN_DEMO('manikant.kella');   -- returns 8 narrated stages
```

## If something looks stale mid-demo

```sql
CALL PREMISEFLOW.APP.MONITORING_CYCLE();
```

Then press **Clear caches** in the app sidebar.
