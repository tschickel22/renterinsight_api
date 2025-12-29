# Loan → Invoice Integration

## Overview

This integration automatically generates invoices for each loan payment, ensuring proper tracking in both RenterInsight and QuickBooks.

## How It Works

### 1. **Loan Activation Triggers Invoice Generation**
```ruby
loan.activate! 
# → Generates one invoice per payment period (e.g., 24 invoices for 24-month loan)
```

### 2. **Invoice Structure**
Each invoice represents one loan payment:
- **Invoice Number**: `LN-20251229-A1B2C3-PMT-01` (loan number + payment number)
- **Due Date**: Based on loan payment schedule
- **Amount**: Regular payment amount
- **Line Items**:
  - Interest portion
  - Principal portion

### 3. **Status Logic**
- **Overdue**: Due date has passed, unpaid
- **Sent**: Due within 7 days  
- **Draft**: Future payment (more than 7 days out)
- **Paid**: Payment received

### 4. **QuickBooks Sync**
- Loan invoices sync to QB automatically via existing invoice sync
- Each payment syncs as a payment against its invoice
- QB aging reports now show loan payment schedule

## Database Changes

**Migration**: `20251229180101_add_loan_to_invoices.rb`
- Adds `loan_id` to invoices table
- Adds `loan_payment_number` to track which payment (1, 2, 3...)
- Indexes for performance

## Key Files Modified

1. **app/models/loan.rb**
   - Added `has_many :invoices`
   - Added `generate_loan_invoices` method
   - Added callback to generate invoices on activation

2. **app/models/invoice.rb**
   - Added `belongs_to :loan`

3. **lib/tasks/loan_invoices.rake**
   - Rake task to backfill existing loans

4. **scripts/test_loan_invoices.rb**
   - Quick test script

## Usage

### For New Loans
Invoices are generated automatically when you activate a loan:
```ruby
loan = Loan.create!(
  company_id: 1,
  borrower: contact,
  principal_amount: 10000,
  term_months: 24,
  regular_payment_amount: 450,
  interest_rate: 5.0,
  status: 'pending'
)

loan.activate! # ← Generates 24 invoices automatically
```

### For Existing Loans (Backfill)

**Option 1: Test with one loan**
```bash
cd ~/src/renterinsight_api
bin/rails runner scripts/test_loan_invoices.rb
```

**Option 2: Backfill all loans**
```bash
rake loans:generate_invoices
```

**Option 3: Specific loan**
```bash
rake loans:generate_invoices_for_loan[123]
```

## Installation Steps

```bash
cd ~/src/renterinsight_api

# 1. Run migration
bin/rails db:migrate

# 2. Restart Rails
pkill -9 ruby
bin/rails server -b 'ssl://0.0.0.0:3001?cert=localhost+1.pem&key=localhost+1-key.pem'

# 3. Test with one loan
bin/rails runner scripts/test_loan_invoices.rb

# 4. Backfill all existing loans
rake loans:generate_invoices

# 5. Trigger QuickBooks sync via UI
# Go to Settings → QuickBooks → Sync Invoices
```

## Verification

### Check Invoice Generation
```ruby
loan = Loan.find(123)
puts "Loan #{loan.loan_number} has #{loan.invoices.count} invoices"
loan.invoices.each { |i| puts "  #{i.invoice_number}: $#{i.total} due #{i.due_date}" }
```

### Check QuickBooks Sync
1. Go to Finance → Invoices
2. Filter by loan (search for loan number)
3. Should see all payment invoices
4. Trigger QB sync
5. Verify in QuickBooks

## Edge Cases Handled

- **No Contact**: Only generates invoices for Contact borrowers (not Account borrowers)
- **Already Has Invoices**: Won't regenerate if invoices exist
- **Missing Data**: Requires term_months, regular_payment_amount, first_payment_date
- **Past Due**: Automatically marks past-due invoices as 'overdue'

## Future Enhancements

1. **Payment Linking**: Link loan payments to specific invoices
2. **Auto-advance**: When invoice is paid, mark loan payment as complete
3. **Partial Payments**: Handle partial payment application
4. **Early Payoff**: Handle extra principal payments
5. **Late Fees**: Auto-generate late fee invoices

## Troubleshooting

**Invoices not generating?**
```ruby
loan = Loan.find(123)
loan.term_months.present?          # Must be true
loan.regular_payment_amount > 0    # Must be true
loan.first_payment_date.present?   # Must be true
loan.borrower_type == 'Contact'    # Must be true
loan.invoices.none?                # Must be true
```

**Invoices not syncing to QB?**
- Check QB connection in Settings
- Verify invoice has contact_id
- Check sync logs for errors

**Wrong invoice count?**
- Invoices = term_months (one per payment)
- If loan has 24 payments, should have 24 invoices
