---
name: project-weekly-update
description: Weekly review of a dealer's manufactured home setup and installation projects in DealerTide (site prep, foundation, delivery, set, utilities, inspections, punch list, move-in), followed by a plain-language update for each customer. Use when someone asks how their projects or installs are going, what is late or stuck, or wants customer updates written for their home buyers.
---

# Project weekly update

Two outputs: an internal review the dealer reads, then a short customer update per project that the dealer sends themselves. You cannot send anything.

## 1. Gather

1. `list_projects` (active), then `list_projects` with `behind_schedule=true`.
2. `get_project` on every active project. If there are more than 10, ask which to cover, or start with the late ones and the ones that have overdue items.
3. `list_project_tasks` with `overdue_only=true` for anything late across all projects.

## 2. Judge each project honestly

Work only from what the data actually shows:

- **Late phase:** a phase that is not completed or skipped and is past its `estimated_completion`. Give the number of days late.
- **Stuck:** a phase `in_progress` whose `started_at` is well past its `estimated_days`, or one with no steps checked off.
- **Blocked:** an open task with status `blocked`, or a step marked `customer_must_act` that has no `customer_acknowledged_at` yet. The second kind is waiting on the buyer, not the crew.
- **Cost drift:** only when `costs` is present. Compare `actual_cost` with `budget` and give the variance. When `costs` is missing and `costs_hidden` explains why, say once in the internal review that job costs are hidden and how the dealer can turn them on; never in a customer update. When both are missing, the project simply has no costs recorded; say nothing about money.
- **Too thin to judge:** if a project has no estimated dates on its phases and no due dates on its tasks, say it cannot be called late or on time and recommend adding phase dates in DealerTide. Do not guess. It's common for steps to carry no dates of their own. A step with `due_source: "phase"` inherited its phase's date, so treat it as an approximate due date.

Normal setup order is: site prep, foundation or piers, delivery, set and leveling, marriage line on multi-sections, utilities, skirting and steps, inspections, punch list, then move-in or the certificate of occupancy. Point it out when a later phase has started while an earlier required phase is still open.

## 3. Internal review (for the dealer)

One block per project, worst first:

- Customer, home, current phase, percent done, owner, link.
- What is late or blocked, by how many days, and who owns the next step.
- Cost drift, if visible.
- One recommended action.

End with a short list of the three things to do this week.

Then offer to:
- create a task for each blocker (`create_project_task` with an owner and a due date), or
- update a date or assignee (`update_project_task`).

Make a change only after the user says yes to that specific item.

`update_project_task` can email the customer. That happens when checking off a step starts a phase that hasn't started yet, or when the project is set to notify the customer on completions. If the tool stops and says a customer will be notified, tell the user exactly that. Retry with `customer_notification_ok=true` only after they agree. A customer email cannot be recalled.

## 4. Customer updates (for the dealer to send)

One short message per project, addressed to the customer by first name:

- What was finished since last week, what happens next, and roughly when. Use dates only when the phase has an estimated date.
- What, if anything, the customer needs to do. For example, a step marked `customer_must_act`, a utility account to open, or a walkthrough to schedule.
- A friendly, plain tone with no jargon. Two short paragraphs at most.

Never put in a customer update:
- costs, budgets, margins, or internal notes
- blame on a crew, a subcontractor, or the manufacturer
- em dashes or en dashes (use periods, commas, colons or parentheses instead)

If a project is late, say what is being done and the next expected step, without excuses. If the dates are too thin to promise anything, don't promise anything.
