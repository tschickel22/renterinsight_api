# Phase 4B-4E: Buyer Portal Features - Implementation Guide

## Context for New Chat Session

### Project Structure
- **Backend Path:** `\\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api`
- **Frontend Path:** `C:\Users\tschi\src\Platform_DMS_8.4.25\Platform_DMS_8.4.25`
- **Access:** Use WSL paths with `\\wsl.localhost\` prefix for file operations
- **Server Port:** 3001 (not 3000)

### Critical Lessons from Phase 4A

#### 1. SQLite Compatibility Requirements
**NEVER use `jsonb` - SQLite doesn't support it!**

```ruby
# ❌ WRONG (PostgreSQL only):
t.jsonb :metadata, default: {}

# ✅ CORRECT (SQLite compatible):
t.text :metadata

# In model, add:
serialize :metadata, coder: JSON
after_initialize :set_defaults

def set_defaults
  self.metadata ||= {}
end
```

#### 2. Database Operations
```bash
# Always migrate development database explicitly:
cd ~/src/renterinsight_api && bin/rails db:migrate RAILS_ENV=development

# Test database migrates automatically when running specs
```

#### 3. Caching Must Be Enabled
```bash
# Required for rate limiting and any cache-dependent features:
cd ~/src/renterinsight_api && bin/rails dev:cache

# Verify cache is working:
cd ~/src/renterinsight_api && bundle exec rails runner "
puts 'Cache: ' + Rails.cache.class.to_s
Rails.cache.write('test', 'value')
puts Rails.cache.read('test').inspect
"
```

#### 4. Model Requirements
- **Lead** requires: `company_id` (non-null), `source_id` (non-null)
- **Account** requires: `company_id` (optional), `name` (non-null)
- Always check schema for non-null constraints before creating test data

#### 5. Test Data Creation Pattern
```ruby
# Always create required associations first:
company = Company.first_or_create!(name: 'Test Company')
source = Source.first_or_create!(name: 'Portal') { |s| s.is_active = true }

# Then create dependent records:
lead = Lead.create!(
  company: company,
  source: source,
  first_name: 'Test',
  last_name: 'Buyer',
  email: 'test@example.com'
)
```

#### 6. File Access Patterns
```ruby
# Reading files - use Filesystem tool with WSL path:
Filesystem:read_file("\\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api\app\models\lead.rb")

# Writing files - same WSL path:
Filesystem:write_file("\\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api\test_script.rb")
```

### Phase 4A Achievements (COMPLETE ✅)

Successfully built JWT-based authentication system:
- ✅ BuyerPortalAccess model (polymorphic to Lead/Account)
- ✅ JWT token generation/validation (24-hour expiration)
- ✅ Login endpoint with rate limiting (5 attempts/15 min)
- ✅ Magic link authentication (15-min tokens)
- ✅ Password reset flow (1-hour tokens)
- ✅ Profile endpoint with JWT protection
- ✅ Helper methods: `authenticate_portal_buyer!`, `current_portal_buyer`, `authorize_buyer_resource!`
- ✅ 59/59 tests passing

**Test Credentials:**
- Email: testbuyer@example.com
- Password: Password123!

---

## Phase 4B: Quote Management for Buyers

### Objective
Build API endpoints for buyers to view and interact with their quotes through the portal.

### Prerequisites
- Phase 4A complete (authentication working)
- Quotes table exists (from earlier phases)
- BuyerPortalAccess has polymorphic buyer association

### Required Endpoints

#### 1. List Buyer's Quotes
**GET** `/api/portal/quotes`

**Authentication:** Required (JWT)

**Query Parameters:**
- `status` (optional) - filter by status (draft, sent, viewed, accepted, rejected)
- `page` (optional) - pagination
- `per_page` (optional) - items per page (default: 20)

**Response:**
```json
{
  "ok": true,
  "quotes": [
    {
      "id": 1,
      "quote_number": "Q-2025-001",
      "status": "sent",
      "subtotal": "1250.00",
      "tax": "125.00",
      "total": "1375.00",
      "items": [...],
      "valid_until": "2025-11-01",
      "sent_at": "2025-10-15T10:30:00Z",
      "viewed_at": null,
      "created_at": "2025-10-15T10:00:00Z"
    }
  ],
  "pagination": {
    "current_page": 1,
    "total_pages": 3,
    "total_count": 45,
    "per_page": 20
  }
}
```

**Business Rules:**
- Only show quotes where buyer owns the account or lead
- Only show non-deleted quotes (`is_deleted: false`)
- Default sort: newest first (created_at DESC)

#### 2. View Single Quote
**GET** `/api/portal/quotes/:id`

**Authentication:** Required (JWT)

**Response:**
```json
{
  "ok": true,
  "quote": {
    "id": 1,
    "quote_number": "Q-2025-001",
    "status": "sent",
    "subtotal": "1250.00",
    "tax": "125.00",
    "total": "1375.00",
    "items": [
      {
        "description": "Oil Change Service",
        "quantity": 1,
        "unit_price": "45.00",
        "total": "45.00"
      },
      {
        "description": "Brake Pad Replacement",
        "quantity": 2,
        "unit_price": "125.00",
        "total": "250.00"
      }
    ],
    "notes": "All parts include 1-year warranty",
    "valid_until": "2025-11-01",
    "sent_at": "2025-10-15T10:30:00Z",
    "viewed_at": "2025-10-15T14:22:00Z",
    "created_at": "2025-10-15T10:00:00Z",
    "vehicle_info": {
      "vehicle_id": "VIN123",
      "make": "Toyota",
      "model": "Camry",
      "year": 2020
    }
  }
}
```

**Business Rules:**
- Mark quote as viewed (update `viewed_at` timestamp) on first view
- Only allow access if buyer owns the quote
- Return 404 for non-existent or deleted quotes

#### 3. Accept Quote
**POST** `/api/portal/quotes/:id/accept`

**Authentication:** Required (JWT)

**Request Body:**
```json
{
  "notes": "Please schedule for next Monday" // optional
}
```

**Response:**
```json
{
  "ok": true,
  "message": "Quote accepted successfully",
  "quote": {
    "id": 1,
    "status": "accepted",
    "accepted_at": "2025-10-15T15:30:00Z"
  }
}
```

**Business Rules:**
- Can only accept quotes in "sent" or "viewed" status
- Cannot accept expired quotes (past `valid_until` date)
- Updates status to "accepted" and sets `accepted_at` timestamp
- Creates activity/note with acceptance
- Triggers notification to company (future: email)

#### 4. Reject Quote
**POST** `/api/portal/quotes/:id/reject`

**Authentication:** Required (JWT)

**Request Body:**
```json
{
  "reason": "Price is too high" // optional
}
```

**Response:**
```json
{
  "ok": true,
  "message": "Quote rejected",
  "quote": {
    "id": 1,
    "status": "rejected",
    "rejected_at": "2025-10-15T15:35:00Z"
  }
}
```

**Business Rules:**
- Can only reject quotes in "sent" or "viewed" status
- Cannot reject expired quotes
- Updates status to "rejected" and sets `rejected_at` timestamp
- Creates activity/note with rejection reason
- Triggers notification to company

### Implementation Steps

#### Step 1: Create Quotes Controller
**File:** `app/controllers/api/portal/quotes_controller.rb`

```ruby
module Api
  module Portal
    class QuotesController < ApplicationController
      before_action :authenticate_portal_buyer!
      before_action :set_quote, only: [:show, :accept, :reject]
      before_action :authorize_quote_access!, only: [:show, :accept, :reject]
      
      def index
        # Implementation
      end
      
      def show
        # Mark as viewed on first view
        if @quote.viewed_at.nil?
          @quote.update!(viewed_at: Time.current)
        end
        
        # Return quote with full details
      end
      
      def accept
        # Validate and accept quote
      end
      
      def reject
        # Validate and reject quote
      end
      
      private
      
      def set_quote
        @quote = Quote.find_by(id: params[:id], is_deleted: false)
        unless @quote
          render json: { ok: false, error: 'Quote not found' }, status: :not_found
        end
      end
      
      def authorize_quote_access!
        # Check if buyer owns the quote through their buyer record
        buyer = current_portal_buyer.buyer
        
        case buyer
        when Lead
          # Lead owns quote if quote.account.lead == buyer
          unless @quote.account&.leads&.include?(buyer)
            render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
          end
        when Account
          # Account owns quote if quote.account == buyer
          unless @quote.account_id == buyer.id
            render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
          end
        end
      end
      
      def buyer_quotes
        buyer = current_portal_buyer.buyer
        
        case buyer
        when Lead
          # Get quotes for accounts associated with this lead
          account_ids = Account.where(id: buyer.converted_account_id).pluck(:id)
          Quote.where(account_id: account_ids, is_deleted: false)
        when Account
          # Get quotes directly for this account
          Quote.where(account_id: buyer.id, is_deleted: false)
        else
          Quote.none
        end
      end
    end
  end
end
```

#### Step 2: Add Routes
**File:** `config/routes.rb`

```ruby
namespace :api do
  namespace :portal do
    # Auth routes (already exist from Phase 4A)
    post 'auth/login', to: 'auth#login'
    # ... other auth routes
    
    # NEW: Quote routes
    resources :quotes, only: [:index, :show] do
      member do
        post :accept
        post :reject
      end
    end
  end
end
```

#### Step 3: Create Quote Serializer/Presenter
**File:** `app/services/quote_presenter.rb`

```ruby
class QuotePresenter
  def self.basic_json(quote)
    {
      id: quote.id,
      quote_number: quote.quote_number,
      status: quote.status,
      subtotal: quote.subtotal.to_s,
      tax: quote.tax.to_s,
      total: quote.total.to_s,
      valid_until: quote.valid_until,
      sent_at: quote.sent_at,
      viewed_at: quote.viewed_at,
      accepted_at: quote.accepted_at,
      rejected_at: quote.rejected_at,
      created_at: quote.created_at
    }
  end
  
  def self.detailed_json(quote)
    basic_json(quote).merge(
      items: quote.items || [],
      notes: quote.notes,
      custom_fields: quote.custom_fields || {},
      vehicle_info: {
        vehicle_id: quote.vehicle_id,
        # Add vehicle details if available
      }
    )
  end
end
```

#### Step 4: Write Tests
**File:** `spec/controllers/api/portal/quotes_controller_spec.rb`

```ruby
require 'rails_helper'

RSpec.describe Api::Portal::QuotesController, type: :controller do
  let(:company) { create(:company) }
  let(:source) { create(:source) }
  let(:lead) { create(:lead, company: company, source: source) }
  let(:account) { create(:account, company: company) }
  let(:buyer_access) { create(:buyer_portal_access, buyer: lead) }
  let(:quote) { create(:quote, account: account, status: 'sent') }
  
  before do
    # Authenticate
    token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
    request.headers['Authorization'] = "Bearer #{token}"
  end
  
  describe 'GET #index' do
    it 'returns buyer quotes' do
      # Test implementation
    end
    
    it 'filters by status' do
      # Test implementation
    end
  end
  
  describe 'GET #show' do
    it 'returns quote details' do
      # Test implementation
    end
    
    it 'marks quote as viewed' do
      # Test implementation
    end
  end
  
  describe 'POST #accept' do
    it 'accepts a sent quote' do
      # Test implementation
    end
    
    it 'rejects expired quotes' do
      # Test implementation
    end
  end
  
  describe 'POST #reject' do
    it 'rejects a quote with reason' do
      # Test implementation
    end
  end
end
```

#### Step 5: Test Data Script
**File:** `create_test_quote.rb`

```ruby
#!/usr/bin/env ruby
# Create test quote for buyer portal testing

company = Company.first_or_create!(name: 'Test Company')
source = Source.first_or_create!(name: 'Portal') { |s| s.is_active = true }

# Find or create test buyer
lead = Lead.find_or_create_by!(email: 'testbuyer@example.com') do |l|
  l.company = company
  l.source = source
  l.first_name = 'Test'
  l.last_name = 'Buyer'
  l.phone = '555-1234'
end

# Create account for the lead
account = Account.find_or_create_by!(name: 'Test Buyer Account') do |a|
  a.company = company
  a.email = 'testbuyer@example.com'
  a.status = 'active'
end

# Link lead to account
lead.update!(converted_account_id: account.id, is_converted: true)

# Create test quotes
quote1 = Quote.create!(
  account: account,
  quote_number: "Q-TEST-001",
  status: 'sent',
  subtotal: 1250.00,
  tax: 125.00,
  total: 1375.00,
  items: [
    { description: 'Oil Change', quantity: 1, unit_price: '45.00', total: '45.00' },
    { description: 'Tire Rotation', quantity: 1, unit_price: '35.00', total: '35.00' }
  ],
  valid_until: 30.days.from_now.to_date,
  sent_at: Time.current,
  notes: 'Standard maintenance package'
)

quote2 = Quote.create!(
  account: account,
  quote_number: "Q-TEST-002",
  status: 'viewed',
  subtotal: 2500.00,
  tax: 250.00,
  total: 2750.00,
  items: [
    { description: 'Brake Replacement', quantity: 1, unit_price: '450.00', total: '450.00' }
  ],
  valid_until: 15.days.from_now.to_date,
  sent_at: 2.days.ago,
  viewed_at: 1.day.ago,
  notes: 'Brake pads and rotors replacement'
)

puts "✅ Created test quotes:"
puts "   Quote 1: #{quote1.quote_number} - #{quote1.status} - $#{quote1.total}"
puts "   Quote 2: #{quote2.quote_number} - #{quote2.status} - $#{quote2.total}"
puts ""
puts "Test with:"
puts "curl -X GET http://localhost:3001/api/portal/quotes \\"
puts "  -H 'Authorization: Bearer YOUR_TOKEN_HERE'"
```

### Testing Checklist

- [ ] List quotes returns only buyer's quotes
- [ ] List quotes respects status filter
- [ ] List quotes pagination works
- [ ] Show quote marks as viewed on first access
- [ ] Show quote returns full details including items
- [ ] Accept quote works for sent/viewed quotes
- [ ] Accept quote rejects expired quotes
- [ ] Reject quote works with optional reason
- [ ] Authorization prevents access to other buyers' quotes
- [ ] Deleted quotes are not visible

---

## Phase 4C: Document Management

### Objective
Allow buyers to upload and view documents related to their quotes/account.

### Required Endpoints

#### 1. List Documents
**GET** `/api/portal/documents`

**Response:**
```json
{
  "ok": true,
  "documents": [
    {
      "id": 1,
      "filename": "insurance_card.pdf",
      "content_type": "application/pdf",
      "size": 245632,
      "uploaded_at": "2025-10-15T10:00:00Z",
      "category": "insurance",
      "url": "/api/portal/documents/1/download"
    }
  ]
}
```

#### 2. Upload Document
**POST** `/api/portal/documents`

**Request:** multipart/form-data
- `file` - the document file
- `category` - document category (optional)

#### 3. Download Document
**GET** `/api/portal/documents/:id/download`

#### 4. Delete Document
**DELETE** `/api/portal/documents/:id`

### Implementation Notes
- Use Active Storage for file management
- Store documents associated with buyer's account/lead
- Validate file types (PDF, images, common doc formats)
- Limit file size (e.g., 10MB max)
- Track who uploaded (buyer vs company staff)

---

## Phase 4D: Communication Preferences

### Objective
Allow buyers to manage their communication preferences.

### Required Endpoints

#### 1. Get Preferences
**GET** `/api/portal/preferences`

**Response:**
```json
{
  "ok": true,
  "preferences": {
    "email_opt_in": true,
    "sms_opt_in": true,
    "marketing_opt_in": false,
    "notification_preferences": {
      "quote_updates": true,
      "appointment_reminders": true,
      "promotional": false
    }
  }
}
```

#### 2. Update Preferences
**PATCH** `/api/portal/preferences`

**Request:**
```json
{
  "email_opt_in": false,
  "sms_opt_in": true,
  "notification_preferences": {
    "quote_updates": true,
    "promotional": false
  }
}
```

### Implementation Notes
- Update BuyerPortalAccess record
- Track preference changes in `preference_history` (JSON text field)
- Return updated preferences

---

## Phase 4E: Profile Management

### Objective
Allow buyers to view and update their profile information.

### Required Endpoints

#### 1. Get Profile (Enhanced from 4A)
**GET** `/api/portal/profile`

**Response:**
```json
{
  "ok": true,
  "profile": {
    "email": "testbuyer@example.com",
    "first_name": "Test",
    "last_name": "Buyer",
    "phone": "555-1234",
    "account_info": {
      "name": "Test Buyer Account",
      "status": "active"
    },
    "preferences": {
      "email_opt_in": true,
      "sms_opt_in": true
    },
    "stats": {
      "total_quotes": 5,
      "accepted_quotes": 2,
      "last_login": "2025-10-15T10:00:00Z"
    }
  }
}
```

#### 2. Update Profile
**PATCH** `/api/portal/profile`

**Request:**
```json
{
  "first_name": "John",
  "last_name": "Doe",
  "phone": "555-5678"
}
```

#### 3. Change Password
**POST** `/api/portal/profile/change-password`

**Request:**
```json
{
  "current_password": "OldPassword123!",
  "new_password": "NewPassword123!",
  "new_password_confirmation": "NewPassword123!"
}
```

#### 4. Login History
**GET** `/api/portal/profile/login-history`

**Response:**
```json
{
  "ok": true,
  "history": [
    {
      "timestamp": "2025-10-15T10:00:00Z",
      "ip_address": "192.168.1.100",
      "user_agent": "Mozilla/5.0..."
    }
  ]
}
```

---

## Testing Strategy for All Phases

### 1. Unit Tests (RSpec)
- Model validations
- Business logic methods
- Authorization helpers

### 2. Controller Tests (RSpec)
- Endpoint responses
- Authentication requirements
- Authorization checks
- Error handling

### 3. Integration Tests (RSpec)
- End-to-end workflows
- Multi-step processes

### 4. Manual API Tests (cURL)
- Real authentication flow
- File uploads (for Phase 4C)
- Edge cases

---

## Common Patterns to Follow

### 1. Controller Structure
```ruby
module Api
  module Portal
    class ResourceController < ApplicationController
      before_action :authenticate_portal_buyer!
      before_action :set_resource, only: [:show, :update, :destroy]
      before_action :authorize_resource!, only: [:show, :update, :destroy]
      
      def index
        resources = buyer_resources
        render json: { ok: true, resources: resources }
      end
      
      private
      
      def buyer_resources
        # Filter resources by current buyer
      end
      
      def authorize_resource!
        # Check ownership
      end
    end
  end
end
```

### 2. JSON Response Format
```ruby
# Success:
{ ok: true, data: {...} }

# Error:
{ ok: false, error: "Error message" }

# With details:
{ ok: false, error: "Error message", errors: [...] }
```

### 3. Always Use Text for JSON Fields
```ruby
# Migration:
t.text :data_field

# Model:
serialize :data_field, coder: JSON
after_initialize { self.data_field ||= {} }
```

---

## Deployment Checklist

Before considering Phase 4 complete:

- [ ] All endpoints tested and working
- [ ] All tests passing (aim for 100+ tests total)
- [ ] Rate limiting enabled and tested
- [ ] Cache configured properly
- [ ] Database migrations run in all environments
- [ ] Error handling comprehensive
- [ ] Security audit passed
- [ ] Documentation complete
- [ ] Frontend integration tested (if applicable)

---

## Success Criteria

Phase 4 is complete when:
1. ✅ Buyers can authenticate securely (4A)
2. ✅ Buyers can view and interact with quotes (4B)
3. ✅ Buyers can upload/download documents (4C)
4. ✅ Buyers can manage preferences (4D)
5. ✅ Buyers can update profile and change password (4E)
6. ✅ All endpoints properly secured with JWT
7. ✅ All tests passing (150+ tests recommended)
8. ✅ API fully documented

---

## Tips for Success

1. **Always check schema first** - Know the non-null constraints
2. **Use text for JSON** - Never use jsonb with SQLite
3. **Enable caching** - Required for rate limiting
4. **Test with real data** - Create comprehensive test scripts
5. **Follow patterns** - Keep controllers consistent
6. **Security first** - Always authenticate and authorize
7. **Document as you go** - Keep API docs updated
8. **Test incrementally** - Don't build everything then test

---

## Getting Help from Claude

When starting Phase 4B (or any subsequent phase), provide:
1. This entire document
2. Current status (what's working, what's not)
3. Specific error messages if any
4. Schema for relevant tables

Claude will:
- Read the complete implementation plan
- Apply lessons learned from 4A
- Use proper WSL paths
- Follow SQLite compatibility rules
- Create comprehensive tests
- Build incrementally with testing

---

**Ready to begin Phase 4B when you are!** 🚀
