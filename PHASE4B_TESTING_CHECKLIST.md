# Phase 4B Testing Checklist

## Pre-Test Setup
- [ ] Navigate to project: `cd ~/src/renterinsight_api`
- [ ] Cache enabled: `bin/rails dev:cache` (should say "cached")
- [ ] Database migrated: `bin/rails db:migrate RAILS_ENV=development`

## Automated Testing

### Run All Tests
```bash
chmod +x quick_test_phase4b.sh
./quick_test_phase4b.sh
```

### Individual Test Suites
```bash
# Presenter tests (should show 11 passing)
bundle exec rspec spec/services/quote_presenter_spec.rb --format documentation

# Controller tests (should show 25+ passing)
bundle exec rspec spec/controllers/api/portal/quotes_controller_spec.rb --format documentation
```

**Expected Result**: All tests pass ✅

## Manual API Testing

### 1. Setup Test Data
```bash
bin/rails runner create_test_quotes.rb
```
**Expected**: Creates 5 test quotes with various statuses

### 2. Get Authentication Token
```bash
# Store token in variable
TOKEN=$(curl -s -X POST http://localhost:3001/api/portal/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"testbuyer@example.com","password":"Password123!"}' \
  | jq -r '.token')

echo "Token: $TOKEN"
```
**Expected**: Returns JWT token

### 3. List Quotes
```bash
curl -X GET http://localhost:3001/api/portal/quotes \
  -H "Authorization: Bearer $TOKEN" | jq
```
**Expected**: 
- Returns array of quotes
- Only shows test buyer's quotes
- Includes pagination info

### 4. Filter by Status
```bash
# Filter for 'sent' quotes
curl -X GET 'http://localhost:3001/api/portal/quotes?status=sent' \
  -H "Authorization: Bearer $TOKEN" | jq
```
**Expected**: Only quotes with status='sent'

### 5. View Single Quote
```bash
# Get first quote ID from list
QUOTE_ID=$(curl -s -X GET http://localhost:3001/api/portal/quotes \
  -H "Authorization: Bearer $TOKEN" | jq -r '.quotes[0].id')

# View the quote
curl -X GET "http://localhost:3001/api/portal/quotes/$QUOTE_ID" \
  -H "Authorization: Bearer $TOKEN" | jq
```
**Expected**: 
- Returns full quote details
- Includes items array
- If status was 'sent', now shows as 'viewed'

### 6. Accept Quote
```bash
# Find a 'sent' or 'viewed' quote
ACCEPT_ID=$(curl -s -X GET http://localhost:3001/api/portal/quotes \
  -H "Authorization: Bearer $TOKEN" | jq -r '.quotes[] | select(.status=="sent" or .status=="viewed") | .id' | head -1)

# Accept it
curl -X POST "http://localhost:3001/api/portal/quotes/$ACCEPT_ID/accept" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"notes":"Please schedule for Monday"}' | jq
```
**Expected**: 
- Returns success message
- Quote status now 'accepted'
- accepted_at timestamp set

### 7. Reject Quote
```bash
# Find another 'sent' or 'viewed' quote
REJECT_ID=$(curl -s -X GET http://localhost:3001/api/portal/quotes \
  -H "Authorization: Bearer $TOKEN" | jq -r '.quotes[] | select(.status=="sent" or .status=="viewed") | .id' | head -1)

# Reject it
curl -X POST "http://localhost:3001/api/portal/quotes/$REJECT_ID/reject" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"reason":"Found a better price"}' | jq
```
**Expected**: 
- Returns success message
- Quote status now 'rejected'
- rejected_at timestamp set

### 8. Test Authorization (Negative Test)
```bash
# Try to access without token
curl -X GET http://localhost:3001/api/portal/quotes | jq
```
**Expected**: 401 Unauthorized error

### 9. Test Expired Quote (Negative Test)
```bash
# Try to accept an expired quote
EXPIRED_ID=$(curl -s -X GET http://localhost:3001/api/portal/quotes \
  -H "Authorization: Bearer $TOKEN" | jq -r '.quotes[] | select(.valid_until < (now | todate)) | .id' | head -1)

if [ -n "$EXPIRED_ID" ]; then
  curl -X POST "http://localhost:3001/api/portal/quotes/$EXPIRED_ID/accept" \
    -H "Authorization: Bearer $TOKEN" | jq
else
  echo "No expired quotes found in test data"
fi
```
**Expected**: 422 error saying quote is expired

## Verification Checklist

### Functionality
- [ ] List quotes returns correct quotes
- [ ] Filtering by status works
- [ ] Pagination works (test with per_page=1)
- [ ] Show quote returns full details
- [ ] Show marks quote as viewed (first time only)
- [ ] Accept works for sent/viewed quotes
- [ ] Accept fails for draft/accepted/rejected quotes
- [ ] Accept fails for expired quotes
- [ ] Reject works for sent/viewed quotes
- [ ] Reject fails for draft/accepted/rejected quotes
- [ ] Reject fails for expired quotes
- [ ] Notes created on accept/reject

### Authorization & Security
- [ ] Requires JWT token
- [ ] Returns 401 without token
- [ ] Returns 403 for other buyer's quotes
- [ ] Only shows non-deleted quotes
- [ ] Soft-deleted quotes don't appear

### Data Integrity
- [ ] Money formatted correctly (2 decimals)
- [ ] Items array formatted properly
- [ ] Timestamps included
- [ ] Account info included
- [ ] Vehicle info included (when present)

## Success Criteria

✅ All automated tests pass (36+)
✅ All manual API tests work as expected
✅ Authorization is secure
✅ Data is correctly formatted
✅ Error handling works properly

## Troubleshooting

### Tests Failing?
1. Check cache: `bin/rails dev:cache`
2. Ensure Phase 4A works: `bundle exec rspec spec/controllers/api/portal/auth_controller_spec.rb`
3. Check database: `bin/rails db:migrate RAILS_ENV=development`

### Can't Get Token?
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
end
BuyerPortalAccess.find_or_create_by!(buyer: lead, email: 'testbuyer@example.com') do |b|
  b.password = 'Password123!'
  b.password_confirmation = 'Password123!'
end
puts '✅ Test buyer ready'
"
```

### No Quotes Showing?
```bash
# Regenerate test data
bin/rails runner create_test_quotes.rb
```

### Server Not Running?
```bash
# Start server on port 3001
bin/rails s -p 3001
```

---

## Final Verification

Run the complete test suite:
```bash
./quick_test_phase4b.sh
```

**All green? Phase 4B is complete! 🎉**
