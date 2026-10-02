---
name: build-annual-budget
description: Build or revise a manufactured housing dealership's annual budget in DealerTide by interviewing the owner, checking their real books where history exists, and saving it as a draft. Use when someone asks to make, plan, set up, rough out or revise a budget, a forecast for next year, or "what should we budget for". Needs the DealerTide connector.
---

# Build an annual budget

You are helping a dealer owner (usually not an accountant) put a real budget into DealerTide. The goal is a draft they trust, built on accounts that exist in their chart, that a person then activates in DealerTide. You can never activate, lock or approve a budget. Say so when you finish.

Write plainly. Never use em dashes or en dashes.

## 1. See what is already there

1. `list_budgets` for the year they mean. If a draft already exists for that year and location, offer to revise it (step 6) instead of starting another.
2. `budget_history` for the last fiscal year (and the one before if it is thin). Read `coverage`:
   - 10 or more months: real history. Use it as the starting point and let the interview adjust it.
   - 1 to 9 months: partial. Say so plainly ("Your books only have March through July of last year, so I will treat those as a guide, not the answer"). Do not treat missing months as zero sales.
   - None: this is the common case. Say "There is not enough history in DealerTide to build from, so we will build it from your numbers," and go to the interview.
3. Note the account list in `budget_history` and `get_budget` results. Only budget accounts that exist. If you need one that does not (for example a separate floor plan interest account), tell them to add it under Accounting, Chart of Accounts and leave it out for now. Do not lump it into a wrong account silently.

`get_reference_data` gives locations. Ask whether this budget is company-wide or for one location. Location users can only budget their own location.

## 2. Interview (ask in small groups, accept rough answers)

Sales, the line everything else hangs on:
- How many homes do you expect to sell in the year, and is that new, used or both?
- Average selling price and average front-end gross per home. If they do not know gross, ask for a typical deal: price and what the home cost them landed.
- Seasonality. Ask, do not assume. In most of the US manufactured housing sales slow from November through February and peak spring through summer, but tax refund season (February to April) and local weather change that. Offer that pattern as a starting point and let them correct it, e.g. "Most dealers sell about twice as many homes in May as in January. Is that you?"

Other income: delivery and setup charged to buyers, F&I or lender referral fees, insurance commissions, service and parts, lot or land income.

Cost of sales: cost of homes (from units times average cost), freight, setup and delivery subcontractors (crews, blocking, skirting, A/C, steps), permits and site work if they carry them.

Operating expenses, ask month by month or annual, whichever they know:
- Floor plan interest (ask the lender rate and average units in stock; interest is roughly units times average cost times rate divided by 12 each month).
- Lot rent or mortgage, utilities, insurance.
- Payroll: salaried staff, and sales commissions (often a percent of gross, so it moves with sales).
- Marketing: listing sites, Facebook, signs, events.
- Software, phones, office, vehicle and fuel, professional fees, licensing and bonds.

If they have history, show last year's figure for each and ask "same, more or less?" rather than starting from blank.

## 3. Turn answers into lines

- Revenue for home sales = units by month times average price. Cost of homes = units by month times average cost. Spread units with the seasonality they agreed, then compute each month, so revenue and cost move together.
- Commissions that are a percent of gross follow the same monthly pattern as sales.
- Fixed costs (rent, salaries, software) are even across months unless they say otherwise.
- Each line: `{gl_account_id, months: [12]}` when months differ for a reason, or `{gl_account_id, annual, seasonality}` for a simple spread. Months are in fiscal order; `budget_history.month_labels` names them.
- Put a short `notes` on each line saying how it was worked out ("38 homes at $92,000, spring heavy"). The owner and their accountant will read these.

## 4. Show it before saving

Show a short P&L for the year: revenue, cost of goods sold, gross profit, expenses, net income, plus the three biggest expense lines and the best and worst months. Flag anything that looks off (gross margin under 10 percent or over 35 percent on homes, a month with a loss bigger than two months of profit, payroll over half of gross profit). Ask "Save this as a draft?"

## 5. Save

`create_budget_draft` with name, fiscal_year, location_id if one, and lines. If they want last year's books with a growth figure and history is good, `copy_from_fiscal_year` with `growth_percent` is fine instead. Give them the link from the result and say: "It is saved as a draft. It does not count until someone opens it in DealerTide, checks it and clicks Activate."

## 6. Revise an existing draft

`get_budget` to read it, agree the change, show the before and after for the lines that move, then `update_budget_draft` with only those lines (other lines stay as they are), `remove_gl_account_ids` for lines to drop, or `name` to rename. Active, locked or archived budgets cannot be changed here: tell them to revert it to draft in DealerTide first (an admin can), or offer to draft a new version.

## Later in the year

When they ask how they are doing, use `budget_variance` (ytd, or month with a month like 2026-09). Lead with net income, then the biggest misses in dollars. If nothing is posted for the period, say the books are not caught up yet rather than calling it a miss. Variance is not available for a single location's budget yet; use the company-wide one.
