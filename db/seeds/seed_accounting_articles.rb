# frozen_string_literal: true

# Idempotent seeder: 12 help articles for the Accounting module.
# Skips any article whose slug already exists.
#
# Run:  bin/rails runner db/seeds/seed_accounting_articles.rb

def resolve_module(key)
  Knowledge::Module.find_by(key: key) ||
    Knowledge::Module.find_by(key: key.to_s.sub(/s\z/, '')) ||
    Knowledge::EntityAlias.find_by(alias_name: key.to_s)&.then { |a| Knowledge::Module.find_by(key: a.canonical_key) }
end

ARTICLES = [
  # ================================================================ Accounting
  {
    module_key: 'accounting', slug: 'accounting-overview', title: 'Accounting Module Overview', article_type: 'concept',
    excerpt: 'How the accounting module fits together — chart of accounts, journals, bills, payments, and reports.',
    content: <<~MD
      ## Overview
      The Accounting module is a full double-entry general ledger built into your DMS. Every dollar that moves through invoices, bill payments, deal closes, or manual journal entries lands in the same chart of accounts and shows up on your P&L and Balance Sheet — no separate bookkeeping system required.

      ## Getting There
      1. Click **Accounting** in the left sidebar
      2. The accounting dashboard appears with shortcuts to Journal Entries, Bills, Bank Accounts, and Reports

      ## What's Included
      - **Chart of Accounts** — your hierarchical list of asset, liability, equity, revenue, and expense accounts
      - **Journal Entries** — every posted GL entry, manual or auto-generated
      - **Bills & Bill Payments** — vendor AP workflow with auto-posting to GL
      - **Bank Accounts & Bank Transactions** — import statements, match, categorize, reconcile
      - **Bank Reconciliation** — month-end reconcile against your bank statement
      - **Recurring Journal Entries** — templates that auto-post on a schedule
      - **Financial Reports** — P&L, Balance Sheet, AR Aging, AP Aging, Trial Balance, GL Detail
      - **Universal Import** — bring in data from QuickBooks, FreshBooks, or CSV

      ## Double-Entry in Practice
      Every transaction is at least two lines, and total debits must equal total credits — the system enforces this on save. For example, when you record a bill from a flooring contractor for $4,500:
      - **Debit** Cost of Goods Sold (or whichever expense line you chose) — $4,500
      - **Credit** Accounts Payable — $4,500

      When you later pay it from your operating bank account:
      - **Debit** Accounts Payable — $4,500
      - **Credit** Operating Bank — $4,500

      Both entries are auto-generated for you when you save the bill and record the payment.

      ## How It Connects to Other Modules
      - **Invoices** — sending or marking an invoice paid posts a journal entry (debit AR or bank, credit revenue)
      - **Bill Payments** — posting a payment debits AP and credits the bank GL account
      - **Deal Close** — closing a deal can trigger revenue recognition entries via deal-close hooks
      - **Bank Transactions** — categorizing an imported transaction can auto-post a journal entry
      - **Recurring Entries** — fire on schedule so monthly rent or depreciation hits the books without you remembering

      ## Fiscal Year
      Set your fiscal year start month under **Accounting Settings**. Every journal entry is auto-stamped with `fiscal_year` and `fiscal_period` based on its entry date so reports can group by your real reporting periods.

      ## Tips & Best Practices
      > **Tip:** Set up your chart of accounts BEFORE you start posting bills or recording payments. Reorganizing the COA after months of activity is painful.

      > **Note:** The accounting module is location-aware. If your dealer group runs multiple lots, see [Multi-Location Accounting](/help/articles/location-accounting) for how to keep books consolidated or per-lot.

      ## Related Features
      - Managing Your Chart of Accounts
      - Creating and Managing Journal Entries
      - Recording Bills and Expenses
      - Running Financial Reports
    MD
  },
  {
    module_key: 'accounting', slug: 'chart-of-accounts', title: 'Managing Your Chart of Accounts', article_type: 'guide',
    excerpt: 'Build, organize, and maintain the chart of accounts that drives every financial report.',
    content: <<~MD
      ## Overview
      The Chart of Accounts (COA) is the master list of every "bucket" your money can land in. It drives the P&L, Balance Sheet, and every dropdown when you record a bill, payment, or journal entry.

      ## Getting There
      1. Click **Accounting** in the left sidebar
      2. Click **Chart of Accounts**
      3. The account tree appears, ordered by account number

      ## Account Types
      Every account belongs to one of five types:
      - **Asset** — what you own (bank accounts, AR, inventory, fixed assets)
      - **Liability** — what you owe (AP, loans, customer deposits)
      - **Equity** — owner stake (retained earnings, owner's equity)
      - **Revenue** — money coming in (home sales, service revenue)
      - **Expense** — money going out (rent, payroll, parts, marketing)

      ## Sub-Types
      Each account also has a sub-type that gives the system semantic hints. Examples:
      - `bank` — bank account (links to a Bank Account record)
      - `accounts_receivable` — customer AR
      - `accounts_payable` — vendor AP (used by bills auto-posting)
      - `cost_of_goods_sold` — direct costs
      - `inventory` — home/RV inventory on the lot
      - `fixed_asset`, `accumulated_depreciation`
      - `operating_expense`, `payroll_expense`, `other_expense`

      The sub-type powers smart defaults — bills auto-post to the AP account whose sub-type is `accounts_payable`, for example.

      ## Adding an Account
      1. From **Chart of Accounts**, click **Add Account**
      2. Fill in:
         - **Account Number** — must be unique within your company. A 4-digit numbering scheme (1000s for assets, 2000s liabilities, 3000s equity, 4000s revenue, 5000s+ expenses) is standard.
         - **Name** — e.g. "Floor Plan Interest"
         - **Account Type** — picks asset/liability/equity/revenue/expense
         - **Sub-Type** — optional but recommended
         - **Parent** — optional. Lets you nest, e.g. "Marketing > Facebook Ads"
         - **Description** — internal note about what belongs here
      3. The **Normal Balance** (debit or credit) is set automatically based on the account type — assets and expenses are debit-normal, liabilities/equity/revenue are credit-normal.
      4. Click **Save**

      ## Parent / Child Hierarchy
      Accounts can nest as deep as you like. A header account (`is_header: true`) groups its children on reports but cannot be posted to directly. For example, "Marketing" might be a header with children "Facebook Ads", "Google Ads", and "Trade Shows" — only the children take postings.

      ## Editing an Account
      1. Click any account row in the tree
      2. The detail panel opens on the right
      3. Update name, description, parent, or active flag
      4. Click **Save**

      Account number and account type are locked once the account has any journal entry lines posted against it.

      ## Deactivating vs Deleting
      Accounts that have ever been posted to **cannot be deleted** — they're part of your audit trail. Instead, set them to **Inactive**. Inactive accounts disappear from dropdowns when posting new entries but still show up on historical reports.

      ## System-Generated vs Custom
      Some accounts are seeded by the system (`is_system: true`) — for example the default Accounts Payable and Accounts Receivable buckets. You can rename them but not delete them. Everything else is yours to organize.

      ## Tips & Best Practices
      > **Tip:** Resist the urge to create a separate revenue account for every product line on day one. Start with broad buckets ("Home Sales", "Parts Revenue", "Service Revenue") and split only when reporting demands it.

      > **Note:** If you're migrating from QuickBooks, run the [Universal Import](/help/articles/accounting-import) wizard first — it brings your COA over and maps account numbers automatically.

      ## Related Features
      - Accounting Module Overview
      - Creating and Managing Journal Entries
      - Importing from QuickBooks and Other Systems
    MD
  },
  {
    module_key: 'accounting', slug: 'journal-entries', title: 'Creating and Managing Journal Entries', article_type: 'guide',
    excerpt: 'Post manual journal entries, void mistakes with reversing entries, and understand auto-generated postings.',
    content: <<~MD
      ## Overview
      A journal entry is the atomic unit of your books — a dated set of debit and credit lines that always balance. Every bill, payment, invoice, and deal close becomes one or more journal entries. You can also post manual entries directly for adjustments, accruals, or corrections.

      ## Getting There
      1. Click **Accounting** > **Journal Entries** in the sidebar
      2. The journal entries list appears with date, entry number, memo, source, and status

      ## Creating a Manual Journal Entry
      1. Click **New Journal Entry**
      2. Set the **Entry Date** — fiscal year and period auto-fill from your accounting settings
      3. Add a **Memo** — a one-line description of why this entry exists
      4. Add at least two lines:
         - Pick a **Chart of Account**
         - Enter either a **Debit** OR a **Credit** amount (not both on the same line)
         - Optional per-line **Memo**, **Location**, **Department**, or links to a **Contact**, **Deal**, or **Vehicle**
      5. Watch the totals at the bottom — total debits must equal total credits or the system rejects the save
      6. Click **Save**

      The system assigns the next sequential **Entry Number** (zero-padded to 6 digits, e.g. `000142`) on save. Entry numbers are unique per company and never reused.

      ## Source Types
      Every journal entry has a `source_type` so you can tell where it came from:
      - **manual** — you created it by hand
      - **auto** — generated from a bill, payment, invoice, or other workflow
      - **recurring** — generated from a recurring template
      - **import** — created during a data import

      Filter the JE list by source_type to find a specific class of entry quickly.

      ## Voiding an Entry
      You cannot edit a posted journal entry once it has been saved — books should be append-only. To reverse an entry:
      1. Open the entry
      2. Click **Void**
      3. Confirm

      The system creates a **reversing entry** dated today that flips every debit to a credit and vice versa, then marks the original as voided. The reversing entry itself is locked so it can never be edited or voided. The original entry stays in the books with a `VOID:` prefix on its memo and a link to the reversal.

      ## Locked Entries
      An entry whose fiscal period has been **closed** is locked — you can't void or edit it. To make corrections in a closed period, post an adjusting entry in an open period instead.

      ## Tips & Best Practices
      > **Tip:** Use the per-line **Location** field on multi-lot dealers — it's how location-filtered reports get their numbers right.

      > **Note:** Entries created by bills, payments, and reconciliations show up here too. If you void an auto-generated entry, the source bill or payment also flips to void in the same transaction.

      ## Related Features
      - Managing Your Chart of Accounts
      - Setting Up Recurring Journal Entries
      - Recording Bills and Expenses
    MD
  },
  {
    module_key: 'accounting', slug: 'bills-and-expenses', title: 'Recording Bills and Expenses', article_type: 'guide',
    excerpt: 'Enter vendor bills, route line items to the right expense accounts, and let the system auto-post AP for you.',
    content: <<~MD
      ## Overview
      A bill is a vendor invoice you owe — flooring from a contractor, parts from your manufacturer, the lot's electric bill, an attorney's hourly invoice. Recording bills lets you track AP, age your payables, and post the right expense to the right GL account in one shot.

      ## Getting There
      1. Click **Accounting** > **Bills**
      2. The bills list appears with vendor, bill number, date, due date, amount, and status

      ## Creating a Bill
      1. Click **New Bill**
      2. Pick a **Vendor** from the dropdown (or create one inline)
      3. Set the **Bill Date** (the date on the vendor's invoice) and **Due Date**
      4. Pick **Payment Terms** — `due_on_receipt`, `net_15`, `net_30`, `net_45`, `net_60`, or `net_90`. The due date auto-calculates if you change terms.
      5. Optional: pick a **Location** to scope this bill to one lot
      6. Add **Line Items**:
         - **Description** — what was purchased
         - **GL Account** — which expense (or asset) account to debit
         - **Amount**
         - Optional **Department** for departmental cost tracking
      7. Add **Tax** if applicable (entered as a flat amount, not a rate)
      8. Click **Save**

      The bill number auto-assigns in the format `BILL-00001` and increments per company.

      ## Status Lifecycle
      Bills move through these statuses:
      - **draft** — you've started entering it but haven't saved line items, or you explicitly saved as draft. Nothing posts to GL.
      - **pending** — saved with line items, no payments yet. The AP journal entry has posted.
      - **partially_paid** — at least one payment recorded but balance > 0
      - **paid** — fully paid, balance = 0
      - **void** — bill was voided; reversing entries created for the bill JE and any payment JEs

      ## Auto-Posting to GL
      When you save a bill (anything other than draft), the system creates a journal entry for you:
      - **Debit** each line item's expense account for its amount
      - **Credit** the Accounts Payable account for the total

      The AP account it picks, in order: the bill's `ap_account` if set → your accounting settings' default AP → the first active COA with sub-type `accounts_payable`.

      ## Voiding a Bill
      1. Open the bill
      2. Click **Void**
      3. Confirm

      The bill flips to `void`, balance goes to 0, the AP journal entry is reversed (creating an offsetting JE), and any payment JEs are also reversed. The bill stays visible in your history but no longer counts on AP Aging or P&L.

      ## Tips & Best Practices
      > **Tip:** Always pick the most specific expense account you can. "Misc Expense" is a black hole that makes your P&L useless when it's time to figure out where margin is leaking.

      > **Note:** If a vendor sends one invoice that covers multiple expense buckets (parts + labor + freight), enter each as its own line item. Each line can hit a different GL account and a different department.

      ## Related Features
      - Paying Bills
      - Managing Your Chart of Accounts
      - Creating and Managing Journal Entries
    MD
  },
  {
    module_key: 'accounting', slug: 'bill-payments', title: 'Paying Bills', article_type: 'guide',
    excerpt: 'Record payments against open bills, handle partial payments, and let the system post AP and bank entries.',
    content: <<~MD
      ## Overview
      Once a bill is in the system, recording a payment marks it paid (or partially paid), reduces your AP balance, and reduces the bank account you paid from — all in one click.

      ## Getting There
      1. Click **Accounting** > **Bills**
      2. Open the bill you want to pay
      3. Click **Record Payment** in the bill detail page

      ## Recording a Payment
      1. **Amount** — defaults to the full balance due. Edit to record a partial payment.
      2. **Payment Date** — the date the money left your bank
      3. **Payment Method** — pick `check`, `print_check`, `ach`, `credit_card`, `cash`, or `other`
      4. **Bank Account** — which bank account the money came from
      5. Optional **Reference** (check number, ACH confirmation, etc.) and **Memo**
      6. Click **Save**

      ## Auto-Posting to GL
      The system creates a journal entry dated to your payment date:
      - **Debit** Accounts Payable — the payment amount
      - **Credit** the bank's GL account — the payment amount

      The bank GL account comes from either the payment's chart_of_account override or the bank account's linked GL account.

      ## Partial Payments
      You can record as many payments against a bill as you need. After each payment:
      - The bill recalculates `amount_paid`, `balance_due`, and `status`
      - If `amount_paid` < total → status stays `partially_paid`
      - If `amount_paid` ≥ total → status flips to `paid`

      ## Payment History
      The bill detail page shows every payment recorded against the bill — date, amount, method, bank, reference, and a link to the auto-generated journal entry. Voided payments stay visible but greyed out.

      ## Print-Check Payments
      If your bank account has check printing enabled and you choose `print_check`, the system queues a `PrintedCheck` record that you can later batch-print from the check printing flow. The check is created as soon as the payment saves.

      ## Tips & Best Practices
      > **Tip:** Pay bills in batches once or twice a week instead of one-by-one. It cuts data entry time and makes reconciliation cleaner.

      > **Note:** The payment date — not the bill date — is what determines which fiscal period the cash hits. If you cut a check on Dec 31 for a January bill, it still hits December's books.

      ## Related Features
      - Recording Bills and Expenses
      - Setting Up Bank Accounts
      - Reconciling Your Bank Account
    MD
  },
  {
    module_key: 'accounting', slug: 'bank-accounts', title: 'Setting Up Bank Accounts', article_type: 'guide',
    excerpt: 'Add your operating, deposit, and credit card accounts and link them to the GL.',
    content: <<~MD
      ## Overview
      A Bank Account in the system represents a real bank account at your financial institution — checking, savings, or credit card. Each one is linked to a GL account on your chart of accounts so payments and deposits hit the right line on your Balance Sheet automatically.

      ## Getting There
      1. Click **Accounting** > **Bank Accounts**
      2. The bank accounts list appears, grouped by location

      ## Adding a Bank Account
      1. Click **Add Bank Account**
      2. Fill in:
         - **Bank Name** — e.g. "Chase", "Wells Fargo"
         - **Account Type** — `checking`, `savings`, or `credit_card`
         - **Account Purpose** — `operating` (day-to-day ops), `deposit` (customer deposits only), or `sync_only` (read-only feed)
         - **Routing Number** — 9 digits, required for checking/savings
         - **Account Number** — required for checking/savings
         - **Location** — which lot/branch this account belongs to
         - **GL Account** — link to the asset account on your COA (e.g. "1010 — Operating Cash")
      3. Click **Save**

      The system stores `display_last_four` for safe display in lists and reports. Full account/routing numbers are masked everywhere except the edit screen.

      ## One Account Per Purpose Per Location
      You can only have one `operating` and one `deposit` bank account per location at a time. This prevents bills and payments from getting routed to the wrong place. If you need to switch accounts, deactivate the old one first.

      ## Connecting via Stripe Financial Connections
      For supported banks, you can connect a live read-only feed via Stripe Financial Connections (FC):
      1. From the bank account detail page, click **Connect Bank Feed**
      2. Authenticate with your bank through Stripe's secure popup
      3. The system pulls transactions automatically going forward

      Sync-only accounts skip the routing/account number requirement since Stripe owns the credentials.

      Connection status is shown on the account detail page:
      - **active** — feed is healthy
      - **disconnected** / **requires_reauth** — re-authenticate via Stripe

      ## Manual vs Connected Accounts
      - **Manual** — you import statements (OFX/QFX/CSV) yourself and reconcile manually
      - **Connected (Stripe FC)** — transactions appear automatically. You still match and reconcile, but no import step

      ## Editing a Bank Account
      Most fields are editable until the account is locked (e.g. synced to a third-party payment processor like Zego). After locking, only display fields (`display_last_four`, `admin_notes`) can change. Routing number, account number, account type, and bank name are immutable once locked.

      ## Tips & Best Practices
      > **Tip:** Create one GL account per real bank account ("1010 — Chase Operating", "1011 — Chase Deposits") rather than lumping all cash into one bucket. Reconciliation is dramatically easier.

      > **Note:** Credit card accounts skip the routing/account number requirement and roll up under liabilities, not assets, on the Balance Sheet.

      ## Related Features
      - Working with Bank Transactions
      - Reconciling Your Bank Account
      - Multi-Location Accounting
    MD
  },
  {
    module_key: 'accounting', slug: 'bank-transactions', title: 'Working with Bank Transactions', article_type: 'guide',
    excerpt: 'Import statements, match to journal entries, categorize the rest, and let bank rules do the boring work.',
    content: <<~MD
      ## Overview
      Bank transactions are the line items off your bank statement — every deposit, withdrawal, fee, and transfer. The transactions list is where you reconcile what your books say against what actually moved through the bank.

      ## Getting There
      1. Click **Accounting** > **Bank Transactions**
      2. Pick a bank account from the selector at the top
      3. The transaction list appears, newest first

      ## Importing Transactions
      For manual (non-connected) bank accounts:
      1. Click **Import Transactions**
      2. Upload an **OFX**, **QFX**, or **CSV** file from your bank's website
      3. Map columns if importing CSV (date, amount, description, type)
      4. Review the preview — duplicates (matched on `fitid`) are skipped automatically
      5. Click **Import**

      For Stripe-connected accounts, transactions appear automatically — no import needed.

      ## Statuses
      Every transaction has one of four statuses:
      - **unmatched** — fresh from the bank, not yet linked to a journal entry
      - **matched** — linked to a JE (either via auto-match, manual match, or by categorizing it)
      - **excluded** — explicitly skipped (transfers between your own accounts, reversals, mistakes)
      - **reconciled** — included in a completed bank reconciliation. Locked from re-matching.

      ## Filtering
      Use the filter bar to narrow by:
      - Status (unmatched / matched / excluded / reconciled)
      - Date range
      - Amount range
      - Deposits vs withdrawals
      - Transaction type (debit/credit/check/transfer/fee/interest/payment/deposit)

      ## Matching to a Journal Entry
      ### Auto-match
      The system tries to auto-match each imported transaction against existing JEs based on date and amount. Successful matches flip to `matched` automatically with `matched_by: 'auto'`.

      ### Manual match
      For unmatched transactions:
      1. Click the transaction row
      2. Click **Match to Journal Entry**
      3. Pick a JE from the suggestions (date and amount-filtered) or search
      4. Confirm

      ## Categorizing (Creating a JE Inline)
      For transactions that don't have an existing JE — bank fees, interest, ad-hoc deposits — categorize them to auto-create a JE:
      1. Click the transaction
      2. Click **Categorize**
      3. Pick a **GL Account** to post the other side to
      4. Optional: pick a **Contact**, edit the memo
      5. Toggle **Create journal entry** to auto-post

      For deposits, the system debits the bank GL and credits the chosen account. For withdrawals, it debits the chosen account and credits the bank GL. The transaction flips to `matched` and links to the new JE.

      ## Excluding a Transaction
      For transfers between your own accounts (which you've already posted as a manual JE) or true mistakes:
      1. Click the transaction
      2. Click **Exclude**
      3. Optionally enter a reason
      4. The transaction stays in the list but doesn't count on reconciliation

      ## Bank Rules
      Bank rules auto-categorize incoming transactions based on description patterns. For example: "Stripe payout → 4100 Card Settlements". Set up rules under **Accounting** > **Bank Rules**, and they fire automatically on every new import or feed update.

      ## Tips & Best Practices
      > **Tip:** Spend 10 minutes a week clearing unmatched transactions. Letting them pile up makes month-end reconciliation a nightmare.

      > **Note:** Bank rules are scoped per bank account. A "Stripe payout" rule on your operating account won't auto-apply on a deposit-only account.

      ## Related Features
      - Setting Up Bank Accounts
      - Reconciling Your Bank Account
      - Creating and Managing Journal Entries
    MD
  },
  {
    module_key: 'accounting', slug: 'bank-reconciliation', title: 'Reconciling Your Bank Account', article_type: 'guide',
    excerpt: 'Match your books to your bank statement at month-end and lock in the period.',
    content: <<~MD
      ## Overview
      Reconciliation is the monthly check that what your books say is in the bank actually matches what your bank says is in the bank. Done right, it catches missed transactions, duplicates, fraud, and bookkeeping mistakes before they snowball.

      ## Getting There
      1. Click **Accounting** > **Bank Reconciliation**
      2. Pick a bank account
      3. Click **Start Reconciliation** (or open one already in progress)

      ## Starting a Reconciliation
      1. Click **New Reconciliation**
      2. Enter the **Statement Date** — the closing date on the statement you're reconciling against (usually the last day of the month)
      3. Enter the **Statement Ending Balance** — the closing balance from your bank statement
      4. The **Beginning Balance** auto-fills from the previous reconciliation's ending balance (or from your initial setup if this is the first one)
      5. Click **Start**

      ## Matching Cleared Transactions
      The reconciliation screen shows every unreconciled transaction in the period:
      - **Deposits** on the left
      - **Withdrawals** on the right

      For each line on your bank statement, find the matching transaction in the list and check its **Cleared** box. As you check items:
      - **Cleared Deposits** total updates at the bottom
      - **Cleared Payments** total updates at the bottom
      - **Calculated Balance** = Beginning + Cleared Deposits − Cleared Payments
      - **Difference** = Statement Ending Balance − Calculated Balance

      Your goal: get **Difference** to **$0.00**.

      ## Handling Discrepancies
      If the difference won't go to zero:
      - **Missing transaction in your books?** Open a new tab, post the journal entry (or import the bank transaction), come back, and check it off
      - **Duplicate in your books?** Void the duplicate JE
      - **Wrong amount?** Compare the bank statement amount vs the JE amount; void and re-post if needed
      - **Bank fees you missed?** Add them as a categorized bank transaction or manual JE

      ## Completing the Reconciliation
      Once Difference = 0:
      1. Click **Complete Reconciliation**
      2. Confirm

      The system:
      - Marks the reconciliation as `completed`
      - Stamps every cleared transaction with the statement date as its `cleared_date`
      - Locks the cleared transactions from being edited
      - Records who completed it and when

      Reconciliations cannot overlap — you can't start a new one with a statement date earlier than your most recent completed one for the same bank account.

      ## Reconciliation History
      The bank reconciliation list shows every past reconciliation with statement date, ending balance, who completed it, and a link to the detail. Re-open any completed reconciliation read-only to inspect what was cleared in that period.

      ## Tips & Best Practices
      > **Tip:** Reconcile monthly without skipping. Falling behind by 3+ months means hunting through 90+ days of transactions to find a $0.42 discrepancy — not fun.

      > **Note:** If your bank statement runs Dec 26 → Jan 25, use Jan 25 as your statement date. Period boundaries don't have to match the calendar month.

      ## Related Features
      - Working with Bank Transactions
      - Setting Up Bank Accounts
      - Running Financial Reports
    MD
  },
  {
    module_key: 'accounting', slug: 'recurring-entries', title: 'Setting Up Recurring Journal Entries', article_type: 'guide',
    excerpt: 'Templates that auto-post on a schedule — rent, depreciation, prepaid amortization, and more.',
    content: <<~MD
      ## Overview
      Recurring journal entry templates take the boring monthly stuff off your plate. Set up the entry once, pick a frequency, and the system posts it automatically until you stop it.

      ## Getting There
      1. Click **Accounting** > **Recurring Journal Entries**
      2. The list shows every recurring template, frequency, next run date, and active status

      ## Common Use Cases
      - **Monthly lot rent** — debit Rent Expense, credit Operating Bank
      - **Equipment depreciation** — debit Depreciation Expense, credit Accumulated Depreciation
      - **Prepaid insurance amortization** — debit Insurance Expense, credit Prepaid Insurance
      - **Loan interest accrual** — debit Interest Expense, credit Accrued Interest Payable
      - **Floor plan interest** — debit Floor Plan Interest, credit Floor Plan Liability

      ## Creating a Template
      1. Click **New Recurring Entry**
      2. Enter:
         - **Name** — what this template represents (e.g. "Monthly Lot Rent — Lot 3")
         - **Memo** — defaults onto each generated entry
         - **Frequency** — `daily`, `weekly`, `monthly`, `quarterly`, or `yearly`
         - **Next Run Date** — when the first entry should post
         - **End Date** — optional. If set, the template auto-deactivates after this date
      3. Add at least two **Template Lines** (must balance):
         - Pick a **Chart of Account**
         - Enter Debit OR Credit amount
         - Optional **Memo**, **Department**, **Location**
      4. Click **Save**

      ## How Posting Works
      A background job runs daily and finds every active template where `next_run_date <= today`. For each one:
      1. A new journal entry is created using the template lines, dated to the next_run_date
      2. The entry is saved (validations still apply — debits must equal credits)
      3. The template's `next_run_date` advances based on frequency:
         - daily → +1 day
         - weekly → +1 week
         - monthly → +1 month
         - quarterly → +3 months
         - yearly → +1 year
      4. The template's `last_run_at` updates

      Generated entries have `source_type: 'recurring'` so you can find them on the JE list.

      ## Pausing and Resuming
      To temporarily stop a template:
      1. Open the template
      2. Toggle **Active** off
      3. Click **Save**

      Inactive templates skip generation. Toggle Active back on (and adjust `next_run_date` if needed) to resume.

      ## Editing a Template
      Editing a template only affects future runs — past auto-generated entries stay as they were. To change a past entry, void it and post an adjustment manually.

      ## End Date
      If a template has an `end_date` and the next computed run date falls after it, the template auto-deactivates and `next_run_date` clears. No more entries generate.

      ## Tips & Best Practices
      > **Tip:** Use a clear naming convention — "Monthly: Lot Rent — Lot 3" tells you the frequency, what it is, and which lot at a glance.

      > **Note:** If you change a template after entries have already posted, double-check `next_run_date` isn't in the past — otherwise the next nightly job will catch it up by posting an entry for the missed date.

      ## Related Features
      - Creating and Managing Journal Entries
      - Managing Your Chart of Accounts
      - Multi-Location Accounting
    MD
  },
  {
    module_key: 'accounting', slug: 'financial-reports', title: 'Running Financial Reports', article_type: 'guide',
    excerpt: 'P&L, Balance Sheet, AR/AP Aging, Trial Balance, and General Ledger detail — with date and location filters.',
    content: <<~MD
      ## Overview
      The accounting module ships with the standard financial reports every dealer needs: profit, equity position, who owes you, who you owe, and the GL detail behind it all.

      ## Getting There
      1. Click **Accounting** > **Reports**
      2. Pick a report from the list

      ## Profit & Loss (P&L)
      Shows revenue minus expenses for a chosen date range, with net income at the bottom.
      - **Date Range** — pick "This Month", "Last Month", "QTD", "YTD", "Last Year", or a custom range
      - **Comparison** — optional: compare to the same range last year
      - **Group By** — none, location, or department
      - Use case: "How much did we make in November?" or "Margin by lot YTD?"

      ## Balance Sheet
      Snapshot of assets, liabilities, and equity as of a point in time.
      - **As Of Date** — defaults to today
      - Assets must equal Liabilities + Equity (the report errors loudly if they don't, which means a posting bug)
      - Use case: end-of-quarter equity position, lender packets, year-end statements

      ## AR Aging
      Open invoices grouped by how late they are: Current / 1-30 / 31-60 / 61-90 / 90+.
      - **As Of Date** — defaults to today
      - Drill into any bucket to see the invoices and customers
      - Use case: collections priority list

      ## AP Aging
      Mirror of AR Aging — bills you owe vendors, grouped by how overdue they are.
      - Use case: cash flow planning, paying the most-aged bills first to protect vendor relationships

      ## General Ledger Detail
      Every journal entry line for a given account or set of accounts within a date range.
      - **Account** — pick one or "All"
      - **Date Range**
      - Use case: "Why is Marketing Expense so high this month?" → drill into the account

      ## Trial Balance
      Every account with its debit and credit totals as of a point in time. Total debits = total credits at the bottom (or your books are off and need investigation).
      - Use case: month-end sanity check, prep for closing

      ## Filtering by Location
      Reports respect the **Location selector** in the page header:
      - Pick "All Locations" → consolidated view
      - Pick a specific location → only journal entry lines stamped to that location count

      ## Exporting
      Every report has **Export** in the top-right:
      - **CSV** — for Excel/Sheets analysis
      - **PDF** — formatted for printing or sending to your CPA

      ## Saved Views
      Apply your filters, click **Save View**, name it ("November Lot 3 P&L"), and it appears under your saved views for one-click reload later.

      ## Tips & Best Practices
      > **Tip:** Run P&L and Balance Sheet at the end of every month BEFORE you close the period. Catching a posting mistake while the period is still open means you can edit the original entry instead of posting a confusing adjustment.

      > **Note:** Reports use entry_date, not created_at. A bill posted today but dated last month appears in last month's P&L.

      ## Related Features
      - Managing Your Chart of Accounts
      - Reconciling Your Bank Account
      - Multi-Location Accounting
    MD
  },
  {
    module_key: 'accounting', slug: 'accounting-import', title: 'Importing from QuickBooks and Other Systems', article_type: 'guide',
    excerpt: 'Bring your chart of accounts, vendors, and transactions over from QuickBooks, FreshBooks, or any CSV export.',
    content: <<~MD
      ## Overview
      The Universal Import wizard moves data out of QuickBooks (Online or Desktop), FreshBooks, or any CSV export into your accounting module — usually in one shot.

      ## Getting There
      1. Click **Accounting** > **Import**
      2. The Universal Import wizard launches

      ## Supported Sources
      - **QuickBooks Online** — export reports as CSV/Excel from QBO and feed them in
      - **QuickBooks Desktop (IIF)** — export an IIF file from QB Desktop and import directly
      - **FreshBooks** — CSV export from FreshBooks
      - **Generic CSV** — any spreadsheet with the right columns

      ## Step-by-Step
      ### 1. Pick a source
      Choose the source system. The wizard knows the column names each source uses and pre-maps them.

      ### 2. Pick what to import
      One import = one type of data. Run separate imports for:
      - Chart of Accounts
      - Vendors
      - Customers
      - Bills (open AP)
      - Invoices (open AR)
      - Bank Transactions
      - Journal Entries

      Order matters — import COA first, then vendors/customers, then transactions that reference them.

      ### 3. Upload the file
      Drag and drop the export file or click **Browse**.

      ### 4. Map columns
      The wizard shows a preview of the first 10 rows with auto-detected column mapping. Adjust any mappings the system got wrong:
      - Source column on the left
      - Destination field on the right

      For chart of accounts imports, you map source account types ("Bank", "Other Current Asset") to the system's types (asset/liability/equity/revenue/expense).

      ### 5. Preview
      Click **Preview** to see exactly what would be created. Errors and warnings surface here:
      - Duplicate detection (matched on natural keys like account number, bill number)
      - Validation errors (missing required fields, balance mismatches on JEs)
      - Reference errors (bill referencing a vendor that doesn't exist yet)

      Fix issues in your source export and re-upload, or check **Skip duplicates** to proceed.

      ### 6. Run the import
      Click **Start Import**. Rows commit in the background. You'll get a notification when it finishes plus an error report for any rows that failed.

      ## What Carries Over
      - **Chart of Accounts** — account number, name, type, sub-type, parent, normal balance
      - **Vendors / Customers** — name, contact info, default GL accounts
      - **Bills / Invoices** — header + line items, status, dates, amounts
      - **Bank Transactions** — date, amount, description, payee
      - **Journal Entries** — full entry with all lines, source_type stamped as `import`

      ## What Doesn't
      - **Attachments / receipts** — re-attach manually after import if needed
      - **Custom QuickBooks reports** — recreate as Saved Reports
      - **Bank rules** — these are system-specific and need to be re-built
      - **Reconciliation history** — start fresh; imports don't carry the cleared/reconciled flags from QB

      ## Handling Duplicates
      The wizard matches on natural keys per type:
      - COA → account number
      - Bill → bill number + vendor
      - Invoice → invoice number
      - Bank Transaction → fitid (when present)

      You can choose to **Skip**, **Update**, or **Create New** for each duplicate class on the preview screen.

      ## Tips & Best Practices
      > **Tip:** Run a small test import first — 10 accounts and 10 transactions — to validate your column mapping before committing thousands of rows.

      > **Note:** Imports are append-only. There's no "undo import" button. If something goes wrong, you'll need to manually void or delete the affected records, so the preview screen is your friend.

      ## Related Features
      - Managing Your Chart of Accounts
      - Recording Bills and Expenses
      - Working with Bank Transactions
    MD
  },
  {
    module_key: 'accounting', slug: 'location-accounting', title: 'Multi-Location Accounting', article_type: 'guide',
    excerpt: 'Run consolidated books across multiple lots while still seeing per-lot profitability.',
    content: <<~MD
      ## Overview
      Most dealer groups run multiple lots — and most want one consolidated set of books AND per-lot P&L. The accounting module handles both via location stamping on journal entry lines and a location filter on every report.

      ## Getting There
      Location is a header-level concept everywhere in the app. Pick a location from the **Location Selector** in the top header:
      - **All Locations** — consolidated view across the whole company
      - **Specific Location** — scoped to one lot

      ## How Location Scoping Works
      ### Per-line, not per-entry
      Journal entries don't have a single location — each **line** can have its own. This matters because one entry can span multiple locations. For example, a payroll JE might debit Wages Expense for three different locations and credit one consolidated payroll bank account.

      ### What gets stamped
      - **Bills** — bill header has a location; line items inherit it but can override per-line
      - **Bill Payments** — JE lines inherit the bill's location
      - **Manual Journal Entries** — set per line in the entry editor
      - **Recurring Entries** — template lines store a location, generated entries inherit it
      - **Bank Transactions** — inherit the bank account's location when categorized
      - **Invoices / Deals** — JE lines stamp to the invoice or deal's location

      ## Location-Aware Reports
      Every financial report respects the location selector:
      - Pick **All Locations** → all JE lines count → consolidated P&L / Balance Sheet
      - Pick **Lot 3** → only JE lines stamped `location_id = lot_3` count → Lot 3 P&L

      Reports that don't make sense per-location (Trial Balance, Balance Sheet) still respect the filter — useful for validating that each lot's books balance independently.

      ## Bank Accounts Per Location
      Each bank account belongs to one location (except `sync_only` Stripe-feed accounts, which can float). You can have:
      - One **operating** account per location
      - One **deposit** account per location
      - Multiple **sync_only** feeds per location

      This keeps cash from getting mis-routed across lots.

      ## Consolidated vs Per-Location Views
      | View | Use When |
      |------|----------|
      | All Locations | Tax filing, lender packets, owner-level P&L |
      | Per Location  | Lot manager performance, per-lot margin analysis, deciding which lot to invest in |

      Switch between them anytime — no data is duplicated, just filtered.

      ## Tips & Best Practices
      > **Tip:** Train your bookkeepers to ALWAYS stamp the location on every JE line. An unstamped line shows up under "All Locations" only — it disappears from every per-location report and silently distorts comparisons.

      > **Note:** Cross-location transfers (moving inventory or cash from Lot 1 to Lot 3) should be posted as a manual JE with debit lines on one location and credit lines on the other. Both per-location P&Ls reflect the move correctly; the consolidated P&L nets to zero.

      ## Related Features
      - Setting Up Bank Accounts
      - Running Financial Reports
      - Creating and Managing Journal Entries
    MD
  }
].freeze

# ------------------------------------------------------------------
# Seed
# ------------------------------------------------------------------
created = 0
skipped = 0
unresolved = []
errors = []

ARTICLES.each_with_index do |spec, idx|
  if Knowledge::Article.exists?(slug: spec[:slug])
    skipped += 1
    next
  end

  mod = resolve_module(spec[:module_key])
  unless mod
    unresolved << [spec[:slug], spec[:module_key]]
    next
  end

  begin
    Knowledge::Article.create!(
      knowledge_module_id: mod.id,
      title:        spec[:title],
      slug:         spec[:slug],
      excerpt:      spec[:excerpt],
      content:      spec[:content],
      article_type: spec[:article_type],
      position:     idx + 100,
      is_published: true
    )
    created += 1
  rescue ActiveRecord::RecordInvalid => e
    errors << [spec[:slug], e.message]
  end
end

puts "Created: #{created}"
puts "Skipped (slug existed): #{skipped}"
puts "Unresolved module: #{unresolved.inspect}" unless unresolved.empty?
puts "Errors: #{errors.inspect}" unless errors.empty?

puts ""
puts "=== Per-module article counts ==="
Knowledge::Article.group(:knowledge_module_id).count.each do |mid, n|
  m = Knowledge::Module.find_by(id: mid)
  puts "  #{(m&.key || 'unknown').ljust(22)} #{n}"
end
puts ""
puts "Total articles: #{Knowledge::Article.count} (#{Knowledge::Article.published.count} published)"
