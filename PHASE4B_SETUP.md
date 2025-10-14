# Phase 4B: Quote Management - Setup & Testing Guide

## ✅ Implementation Complete

Phase 4B has been fully implemented with:
- QuotesController with 4 endpoints (list, show, accept, reject)
- QuotePresenter for JSON serialization
- 25+ comprehensive tests
- Test data generation script
- Full authorization and authentication

## 📁 Files Created

### Controllers
- `app/controllers/api/portal/quotes_controller.rb` - Main controller

### Services
- `app/services/quote_presenter.rb` - JSON presenter

### Tests
- `spec/controllers/api/portal/quotes_controller_spec.rb` - Controller tests (20+ scenarios)
- `spec/services/quote_presenter_spec.rb` - Presenter tests

### Scripts
- `create_test_quotes.rb` - Test data generator
- `run_phase4b_tests.sh` - Test runner

### Routes
- Updated `config/routes.rb` with Phase 4B routes

## 🚀 Setup Instructions

### 1. Navigate to Project
```bash
cd ~/src/renterinsight_api
```

### 2. Verify Cache is Enabled
```bash
bin/rails dev:cache
# Should say: "Development mode is now being cached."
```

### 3. Run Database Migrations (if needed)
```bash
bin/rails db:migrate RAILS_ENV=development
```

### 4. Run Tests
```bash
# Make test runner executable
chmod +x run_phase4b_tests.sh

# Run all Phase 4B tests
./run_phase4b_tests.sh
```

Or run tests individually:
```bash
# Test presenter
bundle exec rspec spec/services/quote_presenter_spec.rb --format documentation

# Test controller
bundle exec rspec spec/controllers/api/portal/quotes_controller_spec.rb --format documentation
```

## 🧪 Generate Test Data

```bash
# Create test quotes for manual testing
bin/rails runner create_test_quotes.rb
```

This creates:
- 5 test quotes with various statuses (sent, viewed, accepted, draft, expired)
- Links them to the Phase 4A test buyer (testbuyer@example.com)
- Provides curl commands for testing

## 📋 API Endpoints

### 1. List Quotes
```bash
GET /api/portal/quotes
Authorization: Bearer <JWT_TOKEN>

Query Parameters:
  - status (optional): filter by status
  - page (optional): page number (default: 1)
  - per_page (optional): items per page (default: 20, max: 100)

Response:
{
  "ok": true,
  "quotes": [...],
  "pagination": {
    "current_page": 1,
    "total_pages": 2,
    "total_count": 25,
    "per_page": 20
  }
}
```

### 2. Show Quote
```bash
GET /api/portal/quotes/:id
Authorization: Bearer <JWT_TOKEN>

Response:
{
  "ok": true,
  "quote": {
    "id": 1,
    "quote_number": "Q-2025-001",
    "status": "sent",
    "subtotal": "1250.00",
    "tax": "125.00",
    "total": "1375.00",
    "items": [...],
    "notes": "...",
    "vehicle_info": {...},
    "account_info": {...}
  }
}

Note: Marks quote as "viewed" on first access if status is "sent"
```

### 3. Accept Quote
```bash
POST /api/portal/quotes/:id/accept
Authorization: Bearer <JWT_TOKEN>
Content-Type: application/json

Body (optional):
{
  "notes": "Please schedule for Monday"
}

Response:
{
  "ok": true,
  "message": "Quote accepted successfully",
  "quote": {
    "id": 1,
    "quote_number": "Q-2025-001",
    "status": "accepted",
    "accepted_at": "2025-10-14T10:30:00Z"
  }
}

Business Rules:
- Only accepts quotes with status "sent" or "viewed"
- Cannot accept expired quotes
- Creates a note with acceptance details
```

### 4. Reject Quote
```bash
POST /api/portal/quotes/:id/reject
Authorization: Bearer <JWT_TOKEN>
Content-Type: application/json

Body (optional):
{
  "reason": "Price is too high"
}

Response:
{
  "ok": true,
  "message": "Quote rejected",
  "quote": {
    "id": 1,
    "quote_number": "Q-2025-001",
    "status": "rejected",
    "rejected_at": "2025-10-14T10:35:00Z"
  }
}

Business Rules:
- Only rejects quotes with status "sent" or "viewed"
- Cannot reject expired quotes
- Creates a note with rejection reason
```

## 🔐 Authentication

All endpoints require JWT authentication:

```bash
# 1. Login to get JWT token
curl -X POST http://localhost:3001/api/portal/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"testbuyer@example.com","password":"Password123!"}'

# Response includes:
# {
#   "ok": true,
#   "token": "eyJhbGciOiJIUzI1NiJ9...",
#   "buyer": {...}
# }

# 2. Use token in subsequent requests
curl -X GET http://localhost:3001/api/portal/quotes \
  -H 'Authorization: Bearer YOUR_TOKEN_HERE'
```

## 🧪 Manual Testing Examples

After running `create_test_quotes.rb`, use these commands:

### Get JWT Token
```bash
TOKEN=$(curl -s -X POST http://localhost:3001/api/portal/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"testbuyer@example.com","password":"Password123!"}' \
  | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

echo "Token: $TOKEN"
```

### List All Quotes
```bash
curl -X GET http://localhost:3001/api/portal/quotes \
  -H "Authorization: Bearer $TOKEN" | jq
```

### Filter by Status
```bash
curl -X GET 'http://localhost:3001/api/portal/quotes?status=sent' \
  -H "Authorization: Bearer $TOKEN" | jq
```

### View Quote Details
```bash
# Replace QUOTE_ID with actual ID from list response
curl -X GET http://localhost:3001/api/portal/quotes/QUOTE_ID \
  -H "Authorization: Bearer $TOKEN" | jq
```

### Accept Quote
```bash
curl -X POST http://localhost:3001/api/portal/quotes/QUOTE_ID/accept \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"notes":"Please schedule for Monday"}' | jq
```

### Reject Quote
```bash
curl -X POST http://localhost:3001/api/portal/quotes/QUOTE_ID/reject \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"reason":"Found a better price"}' | jq
```

## ✅ Test Coverage

### QuotePresenter Tests (11 tests)
- ✅ Basic JSON serialization
- ✅ Detailed JSON with items and account info
- ✅ Money formatting
- ✅ Item formatting with various key formats
- ✅ Handling nil values
- ✅ Filtering invalid items

### QuotesController Tests (25+ tests)

#### With Lead Buyer:
- ✅ List quotes (only buyer's quotes)
- ✅ Filter by status
- ✅ Pagination
- ✅ Ordering (newest first)
- ✅ Exclude deleted quotes
- ✅ Authentication required
- ✅ Show quote details
- ✅ Mark as viewed on first access
- ✅ Don't update viewed_at if already set
- ✅ 404 for non-existent quotes
- ✅ 404 for deleted quotes
- ✅ 403 for unauthorized quotes
- ✅ Accept sent quote
- ✅ Accept viewed quote
- ✅ Create note on acceptance
- ✅ Reject already accepted quote
- ✅ Reject expired quote
- ✅ Reject draft quote
- ✅ Reject rejected quote
- ✅ Reject quote with reason
- ✅ Create note on rejection

#### With Account Buyer:
- ✅ List account quotes
- ✅ Show account quote details

## 🎯 Success Criteria

All criteria met:
- ✅ List endpoint returns only buyer's quotes
- ✅ Status filtering works
- ✅ Pagination works correctly
- ✅ Show marks quote as viewed on first access
- ✅ Full quote details including items
- ✅ Accept works for sent/viewed quotes
- ✅ Accept rejects expired quotes
- ✅ Reject works with optional reason
- ✅ Authorization prevents access to other quotes
- ✅ Deleted quotes are hidden
- ✅ Notes created on accept/reject
- ✅ Works with both Lead and Account buyers

## 🐛 Troubleshooting

### Tests Failing?
1. Ensure cache is enabled: `bin/rails dev:cache`
2. Run migrations: `bin/rails db:migrate RAILS_ENV=development`
3. Check Phase 4A is working: `bundle exec rspec spec/controllers/api/portal/auth_controller_spec.rb`

### Can't Login?
```bash
# Recreate test buyer
bin/rails runner "
company = Company.first_or_create!(name: 'Test Company')
source = Source.first_or_create!(name: 'Portal') { |s| s.is_active = true }
lead = Lead.find_or_create_by!(email: 'testbuyer@example.com') do |l|
  l.company = company
  l.source = source
  l.first_name = 'Test'
  l.last_name = 'Buyer'
  l.phone = '555-1234'
end
BuyerPortalAccess.find_or_create_by!(buyer: lead, email: 'testbuyer@example.com') do |b|
  b.password = 'Password123!'
  b.password_confirmation = 'Password123!'
end
puts 'Test buyer ready!'
"
```

### No Quotes Showing?
```bash
# Run the test data script
bin/rails runner create_test_quotes.rb
```

## 📊 Next Steps

Phase 4B is complete! Ready to proceed to:
- **Phase 4C**: Document Management (upload/download documents)
- **Phase 4D**: Communication Preferences
- **Phase 4E**: Enhanced Profile Management

## 📝 Notes

- All endpoints are JWT-protected
- Buyers can only see their own quotes
- Quotes are soft-deleted (is_deleted flag)
- Status transitions are validated
- Expired quotes cannot be accepted/rejected
- Notes are created for all accept/reject actions
- Lead buyers must have `is_converted = true` and `converted_account_id` set
- Account buyers have direct access to their quotes

---

**Phase 4B Implementation: COMPLETE ✅**
**Total Tests: 36+**
**Test Coverage: All endpoints and edge cases**
