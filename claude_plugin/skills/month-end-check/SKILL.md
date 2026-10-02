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

## How to run it

Gather first, write second. Make every call this skill names, even when the summary
seems to cover it, then write the answer in this order:

1. **Verdict, three lines at most.** Whether the month can close, and the two or three
   findings that matter most. The owner should be able to stop reading here.
2. **Sections 1 to 8 below.** A section that came back empty gets one line ("No bills
   are owed or overdue."). Only sections with something to act on get detail.
   Receivables (section 5) always get full treatment, even in an empty month.
3. **The checklist** (section 9).

**When the books are empty, stop early in what you write, not in what you check.**
Still make every call; a month with an empty P&L can still have overdue bills, won
deals with no close date or aged stock, and any of those goes in the verdict. If
revenue, cost of sales and expenses are all zero for the month and the year to date,
write only: the verdict, the settings or
bank account fix (sections 1 and 2), the bank feed (section 3), receivables by
customer (section 5), and a checklist of at most five items. Do not render the other
sections, not even as one line each. Say at the end that the rest of the close can
run once something is posted.

If a connector call fails with "isn't responding", wait and try it once more. If it
fails again, say which checks could not run and stop rather than guessing.

When two tools give different totals for the same thing, reconcile them out loud
("the summary counts 104 open invoices; 103 are overdue and 1 is not due yet") rather
than silently picking one.

## 1. Overview

Call `accounting_summary` for the month. Report revenue, cost of sales, expenses and
net income in four lines, and anything the tool says it skipped for permissions.

Read `profit_and_loss.fiscal_period` first: if the month is already closed or locked,
say so in the verdict, since nothing posted now would land in it without reopening.
If it says not_set_up, say the month cannot be closed or locked until fiscal periods
are set up under Accounting, Period Close.
Read `dates_apply_to`: only the P&L follows the month's dates; cash, bills and
invoices are as of today. Say "as of today" when you report them.

**Invoices not posting is a headline, not a note.** If `profit_and_loss.notes` says
invoices or payments are not set to post to the books and there are open invoices,
put it in the verdict: "Customer invoices are not set to post, so $X of receivables
has never reached the P&L." Turning it on is done in DealerTide under Accounting,
Settings, and it does not post invoices that already exist.

**An empty month is a finding, not a checklist.** If revenue, cost of sales and
expenses are all zero, say first that nothing was posted to the month and give the
reasons the tools actually show (invoices not set to post, a stopped bank feed).
Do not list a reason the data does not support as a cause.

## 2. Bank accounts

Before the feed: check each account under the summary's `cash.accounts`. Any
`gl_account_warning` (a bank account linked to a GL account that is not a bank or
cash account) goes first and into the verdict, because every line categorized from
that feed posts to the wrong place and fixing the link has to come before any
categorizing. Linking is done in DealerTide under Accounting, Bank Accounts.

## 3. Bank feed

From the summary's `bank_feed`: `unmatched_in_period` for the month,
`unmatched_through_period_end` for the month and before it, the oldest unmatched
line, and `newest_line`. If `feed_note` says the feed looks stopped, lead with that:
nothing after that date can be in the books, and fixing the feed comes before
categorizing. Unmatched bank lines mean the P&L is incomplete; say so in those words
when there are many.

`last_reconciled` empty means no reconciliation date is recorded; say it that way.

If there are more than five unmatched lines, the last sentence of this section must
be the question "Want me to work through the bank feed now?" Put nothing after it in
the section. On yes, follow the bank-feed-cleanup skill. Do not skip this offer, even
if the feed was discussed earlier in the conversation.

## 4. Bills (what we owe)

Call `list_bills`: overdue, and due in the next 14 days, with totals. Flag bills still
in draft, which have not hit the books. Compare total due soon with cash on hand.

## 5. Customer invoices (what we are owed)

`list_invoices` with overdue_only and sort largest: count, total and aging buckets
from `totals`. A dealer chases customers, not invoices: lead with `totals.by_customer`
(customer, open invoices, balance, oldest days past due), then the five largest
overdue invoices by amount and days past due. Say which set a customer table comes
from: in `accounting_summary` it covers all open invoices, in `list_invoices` with
overdue_only it covers overdue ones only, so a customer's numbers can differ between
the two. Use one and name it, or show both and say why they differ.
Use `aging_counts`, `aging_invoices` and each invoice's `aging_bucket` rather than
matching amounts to buckets yourself (several invoices can share one amount). If
`more_not_shown` is above zero, say how many you did not list. Describe what invoices
are only from fields you read; an invoice number pattern is not evidence of what an
invoice is for. Always offer to create follow-up tasks (`create_task`), one per
customer, not one per invoice, with approval.

## 6. Deals

Make both calls:

- `list_deals` with state "any", closed_from and closed_to set to the month: the deals
  actually closed in it (`actual_close_date`).
- `list_deals` with state "won" and no dates: any won deal with no
  `actual_close_date` cannot be placed in a month. List those as "won, close date
  missing."

For each deal closed in the month, say whether it shows a delivery date and a selling
price. Deals show `costs` only when the dealer lets AI apps see cost; when it is
missing, say in one line that unit cost is not visible here. When it is there, note
deals with no unit cost, which leaves gross wrong. Do not compute gross yourself.

Then `list_deals` with state "open": name late-stage deals whose expected close date
passed more than 60 days ago (they closed and nobody moved the stage, or the forecast
is stale), and say how many open deals have no expected close date at all. Ask which;
do not move stages without approval.

## 7. Budget and projects

`list_budgets` for the fiscal year. If there is an active budget, `budget_variance`
for the month and year to date: the five lines that missed by the most dollars, in
plain words. If there is none, say so in one line and offer the build-annual-budget
skill.

`list_projects` with behind_schedule. A late setup job often means a delivery and a
final payment slip into next month; name them. If a project's `deal` is still open or
early stage while the setup work is under way, say so: work is happening on a sale
that is not marked won.

## 8. Inventory and floor plan

`list_inventory` with min_days_in_stock 90 for aged units still in stock: how many,
the oldest few by days in stock, and their asking prices. If units show `costs` with
`floor_plan_amount`, total what is floored on those units and the accrued interest;
an aged unit on floor plan costs money every month it sits. If most units have no
`days_in_stock` (no in-stock date entered), say so in one line instead of guessing
ages. If floor plan figures are absent, say they are not visible here.

## 9. The checklist

End with a short checklist, most important first. Name who should do an item only
when a tool returned that person (a deal's salesperson, a project's owner); never
assign a role the data does not name.

- [ ] Fix the Chase link to GL 1110 before categorizing anything
- [ ] Categorize 41 unmatched bank lines from September
- [ ] Call about invoice 1042, 63 days overdue, $4,800
- [ ] Confirm deal D-2207 delivered; stage still shows negotiation

Then one sentence on whether the month is ready to close.

## Rules

- Read only, unless the person approves a specific change (tasks, notes, categorizing
  via the bank-feed skill). Never move deal stages, change bills or post entries on
  your own.
- Use the numbers the tools return, and say "no date is recorded" rather than
  inferring what an empty field means.
- Never assume a numbered series is complete. If you saw P01, P02, P03 and P05, say
  which numbers you saw; do not write "P01 through P05".
- If the data looks like test or sample records (placeholder names, repeated "New
  Opportunity" deals), say so once at the top so the reader knows how much is signal.
- Plain words for an owner, not accounting jargon. No em dashes or en dashes.
- Use plain headings ("Bank feed", "What you are owed"), never this file's section
  numbers; skipped sections would leave gaps in the numbering.
- A percentage you work out yourself: check the arithmetic and say what it is a
  percentage of.
- Closing the period (locking it) happens in DealerTide. Say so if asked; this
  connector cannot lock periods.
