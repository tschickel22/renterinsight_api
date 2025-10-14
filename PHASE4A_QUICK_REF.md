# Phase 4A Quick Reference

## Start Development Server
```bash
cd ~/src/renterinsight_api
bin/rails s -p 3001
```

## Test Credentials
- **Email:** testbuyer@example.com
- **Password:** Password123!

## API Endpoints (Port 3001)

### Login
```bash
curl -X POST http://localhost:3001/api/portal/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com", "password": "Password123!"}'
```

### Get Profile (requires token)
```bash
TOKEN="your-jwt-token-here"
curl -X GET http://localhost:3001/api/portal/auth/profile \
  -H "Authorization: Bearer $TOKEN"
```

### Request Magic Link
```bash
curl -X POST http://localhost:3001/api/portal/auth/magic-link \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com"}'
```

### Request Password Reset
```bash
curl -X POST http://localhost:3001/api/portal/auth/reset-password \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com"}'
```

## Run Tests
```bash
cd ~/src/renterinsight_api
bundle exec rspec spec/lib/json_web_token_spec.rb \
  spec/models/buyer_portal_access_spec.rb \
  spec/controllers/api/portal/auth_controller_spec.rb \
  --format documentation
```

## Important Setup Commands

### Enable Caching (Required for Rate Limiting)
```bash
bin/rails dev:cache
```

### Run Migrations
```bash
bin/rails db:migrate RAILS_ENV=development
```

### Create Test Buyer
```bash
bundle exec rails runner create_test_buyer.rb
```

## Security Features Active
✅ JWT authentication (24-hour tokens)  
✅ Rate limiting (5 attempts/15 min)  
✅ Password hashing (bcrypt)  
✅ Token expiration (magic link: 15min, reset: 1hr)  
✅ Email enumeration prevention  

## Status: ✅ COMPLETE
All 59 tests passing, API fully functional
