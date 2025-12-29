# Loan Invoice Auto-Send & Portal Visibility

## Overview

This system automatically sends loan invoice reminders before the due date and enables contacts to view their invoices via a secure public link.

## Features Implemented

### 1. **Exclude Future Loan Invoices (Default)**
- Invoice list page now filters out future draft loan invoices by default
- Stats cards exclude future loan invoices (prevents inflated outstanding balances)
- Added toggle button: "Future Loan Invoices" (click to show all)
- **Backend**: Filters on both `index` and `stats` endpoints

### 2. **Auto-Send Invoice Reminders**
- **Scheduled Task**: `rake invoices:send_upcoming_reminders`
- **Trigger**: 3 days before invoice due date
- **Target**: Draft loan invoices with contact email
- **Action**: 
  - Sends email via InvoiceMailer
  - Updates status from `draft` → `sent`
  - Logs success/failure

#### Cron Setup (Production)
```bash
# Add to crontab: Run daily at 9 AM
0 9 * * * cd /app && rake invoices:send_upcoming_reminders RAILS_ENV=production
```

#### Manual Test
```bash
cd ~/src/renterinsight_api
rake invoices:send_upcoming_reminders
```

### 3. **Public Invoice Viewing (Portal)**
- **Public URL**: `https://app.com/invoice/:public_token`
- **No authentication required** - secure via unique token
- **Auto-marks as viewed** when contact opens
- **Shows**:
  - Invoice details (number, date, amounts)
  - Line items
  - Company/location info
  - Payment link (if available)

#### Invoice Model Methods
```ruby
invoice.public_url     # => "https://app.com/invoice/abc123..."
invoice.payment_url    # => "https://app.com/pay/invoice/xyz789..."
invoice.is_overdue     # => true/false
```

#### API Endpoints
```
GET /invoice/:token          # View invoice (public - no auth)
GET /invoice/:token/pdf      # Download PDF (not yet implemented)
```

### 4. **Database Migration**
```ruby
# Adds public_token to invoices table
# Generates tokens for existing invoices automatically
rake db:migrate
```

---

## Usage

### **For Loan Creation:**
1. Create loan and activate
2. System generates 24 invoices (one per month)
3. First few are `overdue` (past due dates)
4. Next is `draft` (due within 3 days → will auto-send)
5. Rest are `draft` (future payments)

### **Auto-Send Behavior:**
**Day -3**: Invoice status=`draft`, due_date = today+3
- Cron runs: `rake invoices:send_upcoming_reminders`
- Email sent to contact
- Status updated: `draft` → `sent`

**Day 0** (Due Date): Invoice is now due
- Status remains `sent` or `viewed`

**Day +1** (Overdue): Past due
- Status automatically becomes `overdue`

### **Portal Access:**
Contacts can view their invoices at:
```
https://staging.crm.landlordinsight.com/invoice/:public_token
```

Include this link in emails:
```ruby
# In InvoiceMailer
"View Invoice: <%= @invoice.public_url %>"
"Pay Now: <%= @invoice.payment_url %>"
```

---

## Files Modified

### Backend:
```
app/models/invoice.rb                                 # Added public_token generation
app/models/loan.rb                                    # Auto-delete invoices when loan deleted
app/controllers/api/v1/invoices_controller.rb         # Filter future loan invoices
app/controllers/public/invoices_controller.rb         # NEW - Public invoice viewing
config/routes.rb                                      # Public invoice routes
db/migrate/20251229190001_add_public_token_to_invoices.rb  # NEW migration
lib/tasks/invoice_reminders.rake                      # NEW - Auto-send task
```

### Frontend:
```
src/modules/finance/pages/InvoicesListPage.tsx        # Toggle for future loan invoices
```

---

## Testing Checklist

### ✅ **Backend**:
- [ ] Run migration: `bin/rails db:migrate`
- [ ] Test auto-send: `rake invoices:send_upcoming_reminders`
- [ ] Test public URL: `curl https://localhost:3001/invoice/:token`

### ✅ **Frontend**:
- [ ] Verify "Future Loan Invoices" button appears
- [ ] Click button - should show all loan invoices
- [ ] Stats should NOT include future loan invoices
- [ ] Invoice list should NOT show future loan invoices by default

### ✅ **End-to-End**:
1. Create loan with Contact borrower
2. Activate loan (generates invoices)
3. Check invoices page - should show only current/overdue
4. Click "Future Loan Invoices" - should show all 24
5. Get public_token from invoice: `Invoice.last.public_token`
6. Visit: `https://localhost:5173/invoice/:token`
7. Should see invoice details (no auth required)

---

## Production Deployment

### 1. Deploy Backend
```bash
cd ~/src/renterinsight_api
git add .
git commit -m "Add auto-send invoice reminders and public portal access"
git push origin staging

# After Render deploys:
# - Migration runs automatically
# - Existing invoices get public_tokens
```

### 2. Setup Cron (Render)
In Render dashboard:
- Go to your API service
- Add Cron Job:
  - **Schedule**: `0 9 * * *` (daily at 9 AM)
  - **Command**: `rake invoices:send_upcoming_reminders`

### 3. Deploy Frontend
```bash
cd /c/Users/tschi/src/Platform_DMS_8.4.25/Platform_DMS_8.4.25
git add .
git commit -m "Add Future Loan Invoices toggle"
git push origin staging
```

### 4. Update Frontend Public Routes
**CRITICAL**: Add `/invoice/:token` to public routes checklist:
- `App.tsx` - Add route BEFORE auth routes
- `useBranding.ts` - Add to `isPublicPage` check
- `api.ts` - Add to `publicPaths` array

---

## Future Enhancements

1. **PDF Generation** - Implement invoice PDF rendering
2. **SMS Reminders** - Add SMS option for reminders
3. **Overdue Reminders** - Send recurring reminders for overdue invoices
4. **Payment Integration** - One-click payment from public invoice page
5. **Read Receipts** - Track when invoice email is opened

---

## FAQs

**Q: Why create all invoices at once?**
A: For accrual accounting - QuickBooks shows future receivables, aging reports work correctly, and it's standard practice for loan accounting.

**Q: Why hide future loan invoices by default?**
A: To prevent clutter - most users only need to see current/overdue invoices. Toggle shows all if needed.

**Q: When do invoices get sent?**
A: 3 days before due date (configurable in rake task). You can also manually send via "Send Invoice" button.

**Q: Can contacts pay from the invoice page?**
A: Yes - the invoice includes a payment link that uses the existing Zego payment flow.

**Q: What if contact doesn't have email?**
A: Auto-send skips invoices without contact email. You'll see a warning in the rake task output.

---

## Troubleshooting

### Invoice not sending:
1. Check contact has email: `Invoice.find(X).contact.email`
2. Check invoice is draft: `Invoice.find(X).status`
3. Check due date is 3 days away: `Invoice.find(X).due_date`
4. Run manually: `rake invoices:send_upcoming_reminders`

### Public URL not working:
1. Check token exists: `Invoice.find(X).public_token`
2. If nil, regenerate: `invoice.update(public_token: SecureRandom.urlsafe_base64(32))`
3. Check route is public (no auth required)

### Toggle not filtering:
1. Check backend logs for filter param: `include_future_loan_invoices`
2. Verify query includes loan_id filter
3. Check stats endpoint also excludes future invoices

---

**Status**: ✅ Ready for staging deployment
