---
name: month-end-check
description: Walk a dealership through closing the month in DealerTide. Checks the bank feed, unpaid bills, open customer invoices, deals sold but not cleanly posted, and results against budget, then produces a short close checklist. Use when an owner, office manager or bookkeeper asks to close the month, whether the books are ready, what is left before month end, or how the month went.
---

# Month-end check

A dealership's month is not closed until the bank feed is worked, bills and customer
invoices are current, every sold deal is in the books, and someone has looked at the
results. This skill checks each of those in DealerTide, says plainly what is done and
what is not, and turns what is not into a short list with owners.

Needs the DealerTide connector and a role that can read accounting. Sections the
person cannot see are skipped and named, never guessed.

## Which month

Default to the month that just ended if today is in the first ten days of a month,
otherwise the current month. Say which one you picked.

## 1. Overview

Call `accounting_summary` for the month. Report revenue, cost of sales, expenses and
net income in four lines, cash per bank account, and anything the tool says it
skipped for permissions.

## 2. Bank feed

From the summary (or `list_bank_transactions` with status unmatched and the month's
dates): how many transactions are still unmatched for the month and before it, and
the oldest. Unmatched bank lines mean the P&L above is incomplete; say so in those
words when there are many.

If there are more than a handful, offer to run the bank-feed-cleanup skill now
rather than working them here.

## 3. Bills (what we owe)

`list_bills`: overdue, and due in the next 14 days, with totals. Flag bills still in
draft, which have not hit the books. Compare total due soon with cash on hand.

## 4. Customer invoices (what we are owed)

`list_invoices` with overdue_only: count, total and aging buckets. Name the five
largest overdue by customer and days. Offer to create follow-up tasks for whoever
owns those customers (`create_task`), one per invoice, with approval.

## 5. Deals

`list_deals` with state "won", then keep the ones closed in the month (check
expected or actual close date on `fetch`). For each, say whether it shows a delivery
date and a selling price. If the dealer allows cost visibility and the person can see
it, note deals with no unit cost, which leaves gross wrong. Do not compute gross
yourself; read what the deal shows.

Also list open deals in late stages (`list_deals` with state "open") whose expected
close date was in the month: either they closed and the stage was not moved, or the
forecast slipped. Ask which; do not move stages without approval.

## 6. Against budget

`list_budgets` for the fiscal year. If there is an active budget, `budget_variance`
for the month and year to date: the five lines that missed by the most dollars, in
plain words ("advertising ran $2,400 over, mostly in the second half"). If there is no
budget, say so in one line and offer the build-annual-budget skill. Do not lecture.

## 7. Projects (if the dealer uses them)

`list_projects` with behind_schedule. A late setup job often means a delivery and a
final payment slip into next month; name them.

## 8. The checklist

End with a short checklist, most important first, each item with who should do it if
the data names someone:

- [ ] Categorize 41 unmatched bank lines from September (bookkeeper)
- [ ] Post or delete 3 draft bills
- [ ] Call about invoice 1042, 63 days overdue, $4,800
- [ ] Confirm deal D-2207 delivered; stage still shows negotiation

Then one sentence on whether the month is ready to close.

## Rules

- Read only, unless the person approves a specific change (tasks, notes, categorizing
  via the bank-feed skill). Never move deal stages, change bills or post entries on
  your own.
- Use the numbers the tools return. If two tools disagree, show both and say which
  report in DealerTide to check; do not reconcile by guessing.
- Plain words for an owner, not accounting jargon. No em dashes or en dashes.
- Closing the period (locking it) happens in DealerTide. Say so if asked; this
  connector cannot lock periods.
