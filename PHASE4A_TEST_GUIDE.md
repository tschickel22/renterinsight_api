# PHASE 4A: AUTHENTICATION FOUNDATION - TEST CHECKLIST

## Quick Start Commands

### 1. Run RSpec Tests (COPY/PASTE THIS)
```bash
cd /home/tschi/src/renterinsight_api && \
bundle install && \
RAILS_ENV=test bundle exec rails db:migrate && \
bundle exec rspec spec/lib/json_web_token_spec.rb \
  spec/models/buyer_portal_access_spec.rb \
  spec/controllers/api/portal/auth_controller_spec.rb \
  --format documentation
```

### 2. Start Rails Server (in separate terminal)
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails server
```

### 3. Create Test Buyer (after server is running)
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails runner "
lead = Lead.create!(
  first_name: 'Test',
  last_name: 'Buyer',
  email: 'testbuyer@example.com',
  phone: '555-1234'
)

buyer_access = BuyerPortalAccess.create!(
  buyer: lead,
  email: 'testbuyer@example.com',
  password: 'Password123!',
  password_confirmation: 'Password123!',
  portal_enabled: true
)

puts '✅ Created test buyer: testbuyer@example.com'
puts '   Password: Password123!'
"
```

### 4. Test Login API
```bash
curl -X POST http://localhost:3000/api/portal/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "testbuyer@example.com",
    "password": "Password123!"
  }' | jq '.'
```

---

## Test Checklist

### ✅ Model Tests
- [ ] BuyerPortalAccess validates email presence
- [ ] BuyerPortalAccess validates email uniqueness (case-insensitive)
- [ ] BuyerPortalAccess validates email format
- [ ] BuyerPortalAccess downcases email before save
- [ ] BuyerPortalAccess has secure password
- [ ] generate_reset_token creates token and expiration
- [ ] generate_login_token creates token and expiration
- [ ] reset_token_valid? checks expiration correctly
- [ ] login_token_valid? checks expiration correctly
- [ ] record_login! updates login stats

### ✅ JWT Tests
- [ ] JsonWebToken.encode creates valid JWT
- [ ] JsonWebToken.encode includes expiration
- [ ] JsonWebToken.encode defaults to 24 hours
- [ ] JsonWebToken.decode decodes valid tokens
- [ ] JsonWebToken.decode returns nil for invalid tokens
- [ ] JsonWebToken.decode returns nil for expired tokens
- [ ] JsonWebToken.decode returns HashWithIndifferentAccess

### ✅ Controller Tests
- [ ] POST /api/portal/auth/login with valid credentials returns JWT
- [ ] POST /api/portal/auth/login records login
- [ ] POST /api/portal/auth/login handles case-insensitive email
- [ ] POST /api/portal/auth/login rejects invalid password
- [ ] POST /api/portal/auth/login rejects non-existent email
- [ ] POST /api/portal/auth/login rejects disabled portal
- [ ] Rate limiting blocks after 5 attempts
- [ ] POST /api/portal/auth/magic-link generates token
- [ ] POST /api/portal/auth/magic-link sends email
- [ ] POST /api/portal/auth/magic-link returns success for invalid email (security)
- [ ] GET /api/portal/auth/verify/:token returns JWT
- [ ] GET /api/portal/auth/verify/:token records login
- [ ] GET /api/portal/auth/verify/:token clears login token
- [ ] GET /api/portal/auth/verify/:token rejects expired token
- [ ] POST /api/portal/auth/reset-password generates reset token
- [ ] POST /api/portal/auth/reset-password sends email
- [ ] PATCH /api/portal/auth/reset-password/:token updates password
- [ ] PATCH /api/portal/auth/reset-password/:token clears reset token
- [ ] PATCH /api/portal/auth/reset-password/:token rejects mismatched passwords
- [ ] PATCH /api/portal/auth/reset-password/:token rejects expired token
- [ ] GET /api/portal/auth/profile returns buyer data when authenticated
- [ ] GET /api/portal/auth/profile returns unauthorized when not authenticated

---

## Manual API Testing

### Test 1: Login
```bash
# Should return: { "ok": true, "token": "...", "buyer": {...} }
curl -X POST http://localhost:3000/api/portal/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com", "password": "Password123!"}' \
  | jq '.'
```

### Test 2: Get Profile (use token from login)
```bash
# Replace YOUR_TOKEN_HERE with the token from login
curl -X GET http://localhost:3000/api/portal/auth/profile \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  -H "Content-Type: application/json" \
  | jq '.'
```

### Test 3: Request Magic Link
```bash
# Should return: { "ok": true, "message": "..." }
curl -X POST http://localhost:3000/api/portal/auth/magic-link \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com"}' \
  | jq '.'

# Check Rails logs for the magic link token:
# tail -f log/development.log | grep "Magic link"
```

### Test 4: Request Password Reset
```bash
# Should return: { "ok": true, "message": "..." }
curl -X POST http://localhost:3000/api/portal/auth/reset-password \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com"}' \
  | jq '.'

# Check Rails logs for the reset token:
# tail -f log/development.log | grep "Reset token"
```

### Test 5: Invalid Login
```bash
# Should return: { "ok": false, "error": "Invalid email or password" }
curl -X POST http://localhost:3000/api/portal/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com", "password": "WrongPassword"}' \
  | jq '.'
```

### Test 6: Unauthorized Access
```bash
# Should return: { "error": "Unauthorized" }
curl -X GET http://localhost:3000/api/portal/auth/profile \
  -H "Content-Type: application/json" \
  | jq '.'
```

---

## Success Criteria

### Must Pass:
✅ All RSpec tests pass (JWT, Model, Controller)
✅ Can create BuyerPortalAccess with password
✅ POST /api/portal/auth/login returns JWT on valid credentials
✅ JWT token works for authenticated endpoints
✅ Magic link generation works
✅ Password reset token generation works
✅ Rate limiting works on auth endpoints
✅ Invalid credentials are rejected
✅ Unauthorized access is blocked

### Files Created:
- [x] lib/json_web_token.rb
- [x] db/migrate/TIMESTAMP_create_buyer_portal_accesses.rb
- [x] app/models/buyer_portal_access.rb
- [x] app/controllers/application_controller.rb (helpers added)
- [x] app/controllers/api/portal/auth_controller.rb
- [x] app/services/buyer_portal_service.rb
- [x] config/routes.rb (portal routes added)
- [x] spec/lib/json_web_token_spec.rb
- [x] spec/models/buyer_portal_access_spec.rb
- [x] spec/controllers/api/portal/auth_controller_spec.rb
- [x] spec/factories/buyer_portal_accesses.rb

---

## Troubleshooting

### If tests fail with "uninitialized constant JWT"
```bash
# Add jwt gem to Gemfile
bundle add jwt

# Or manually add to Gemfile:
# gem 'jwt'

bundle install
```

### If tests fail with "BCrypt::Errors::InvalidHash"
```bash
# Make sure password_digest column exists in migration
# Check that has_secure_password is in the model
```

### If routes don't exist
```bash
# Check routes were added to config/routes.rb
bundle exec rails routes | grep portal
```

### Check what's in the database
```bash
bundle exec rails console
# Then in console:
BuyerPortalAccess.first
Lead.first
```

---

## Next Steps After Phase 4A

Once all tests pass:
1. ✅ Phase 4A Complete: Authentication Foundation
2. 📋 Phase 4B: Quote Management APIs
3. 📋 Phase 4C: Document Management APIs
4. 📋 Phase 4D: Communication Preferences
5. 📋 Phase 4E: Profile Management

---

## Notes

- Magic link and password reset emails are logged (not sent) in Phase 4A
- Email sending will be implemented in Phase 4B using existing Communications system
- JWT tokens expire after 24 hours by default
- Login tokens expire after 15 minutes
- Reset tokens expire after 1 hour
- Rate limiting: 5 attempts per 15 minutes per IP
