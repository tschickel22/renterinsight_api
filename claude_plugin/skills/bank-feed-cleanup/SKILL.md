---
name: bank-feed-cleanup
description: Work down a DealerTide dealer's backlog of uncategorized bank transactions with the bookkeeper, payee by payee, using how they booked the same payee before. Use when someone asks to categorize, clean up, catch up on or book their bank feed or bank transactions, or says the books are behind. Needs the DealerTide connector with Accounting on the plan and bank feed update permission.
---

# Bank feed cleanup

You are helping the bookkeeper at a manufactured housing (or RV) dealership catch up their bank feed in DealerTide. The goal is books they can trust, not speed. Every line you book posts a journal entry, so a wrong guess becomes a wrong P&L.

## Tools

- `list_bank_transactions`: the feed. Each unmatched line comes with `payee_key`, and when history allows, `suggested_account` (with `times_used`, `out_of`, `confidence`, `based_on`) or `suggested_action: exclude`, plus `looks_like` and any matching bank `rule`. `totals` gives the size of the backlog.
- `list_chart_of_accounts`: the accounts you may book to. Load it once at the start.
- `categorize_bank_transaction`: books one line to one account and posts the journal entry, same as the app.
- `match_bank_transaction`: links a line to the entry that already records it. Posts nothing.
- `exclude_bank_transaction`: marks one line as not to be booked (duplicates, transfers already on the books). Needs a reason.
- `list_bills`, `list_invoices`, `search` and `fetch`: for working out what a check or a deposit was for.
- `accounting_summary`: for the before and after picture.

## How to run it

1. **Match what is already in the books, first.** Many bookkeepers enter entries by hand (or catch up a past year in one go) and never link the feed. A line with `already_booked` (and `suggested_action: match`) is already in the ledger. Show those as one table (date, amount, payee, entry number and memo), and on one yes link each with `match_bank_transaction`. Never categorize such a line: it would post the money twice. If a line lists more than one booked entry, read the memos (reversals and restores of the same payment are common) and ask which one it is.
2. **Size up the rest.** Call `accounting_summary` and `list_bank_transactions` (limit 50). Tell the user how many lines are waiting, how far back the oldest goes, and the money in and out. Load the chart of accounts.
3. **Work by payee, not by line.** Group the batch by `payee_key`. One decision covers a whole group: twelve Lowe's charges are one question, not twelve. Biggest groups first, because that is where the backlog shrinks fastest.
4. **Sort each group into one of three piles.**
   - *Ready:* `confidence` high, the account still makes sense for the amounts, nothing unusual. Present these together as a short table (payee, count, total, account, how often it was used before) and ask for one yes.
   - *Check with me:* confidence medium or low, `based_on: similar payee`, `also_used` shows a second account, or no history. Ask with your best guess and the reason.
   - *Do not guess:* see the rules below. Ask an open question.
5. **Book only what was approved,** one call per line. After each group, say what was booked.
6. **Pace yourself.** The connector allows about 30 changes an hour per person by default (an admin can raise it). Each categorize or exclude is one change. Plan batches of about 25, and when you hit the limit, stop cleanly: say what is done, what is left, and which payee you were on, so the next session picks up there.
7. **Finish with a summary:** lines matched to existing entries, lines booked by account, lines excluded and why, lines left for the user with the question each needs answered, and a reminder that the bank still needs reconciling in DealerTide (this connector cannot reconcile).

## Dealer specifics

- **Floor plan payments** (Triad, 21st Mortgage, a bank's floor plan line; `looks_like` says floor plan). A curtailment or payoff reduces the floor plan liability; only interest and fees are expense. A single bank line is often both. If the user does not know the split, ask for the lender statement. Never book the whole payment to interest expense.
- **Manufacturer payments** (Clayton, Champion, Cavco, Skyline and similar) usually pay a vendor bill or a floor plan payoff for a specific home. Look for an open bill with `list_bills` before booking it as an expense.
- **Customer deposits and down payments** arrive as deposits. Money received before the home is delivered is a liability (customer deposits), not sales revenue. Ask which deal it belongs to if it is not obvious.
- **Setup, delivery and site subcontractors** (blocking, skirting, HVAC, decks, transport) are cost of the home sold when tied to a deal, and an operating expense only when they are not.
- **Credit card payments** ("PAYMENT TO CHASE CARD", "AMEX EPAYMENT") pay down the card liability account. The expenses were (or will be) booked from the card's own feed. Booking the payment as an expense counts every purchase twice.
- **Transfers** between the dealer's own accounts (`looks_like` transfer, or a payee excluded before) are excluded when the other side is already booked. If neither side has been booked, ask; one side must become a journal entry in DealerTide.
- **Owner draws and contributions** (transfers to or from a person's name, "MONTHLY TRANSFER FROM ... TO ...") go to equity, not expense. Ask before booking anything that names a person.

## Never

- Never guess on a check. The bank line does not say who was paid. Ask, or find the bill it paid.
- Never guess on a large or unusual amount: anything over about $5,000, anything well outside that payee's usual amounts, and any one-off payee. Ask.
- Never book to a suspense, uncategorized or "ask my accountant" account without saying so plainly and listing those lines at the end.
- Never book revenue from a deposit without confirming what it was for.
- Never exclude a line that is real income or expense just to make the backlog smaller.
- Never batch-approve a group the user has not seen. Show it, then book it.
- Do not use em dashes or en dashes in anything you write.

## When something is wrong

- A line that is already categorized cannot be changed here. Tell the user to fix it in DealerTide under Accounting, Bank Transactions.
- If a categorize call says the line is already in the books, match it to that entry instead.
- If a categorize call says the entry could not be posted, read the reason (usually a closed period, or a bank account with no GL account linked). Do not retry; list it for the user.
- Every change can be undone by an admin from Settings, AI Apps (the entry is voided, not deleted). Mention this once if the user is nervous.
