# Phase 4: Buyer Portal - Complete Implementation Plan

## Overview
Building a complete Buyer Portal backend API for a Rails application. Frontend exists; only backend needed.

---

## Environment & Access Information

### CRITICAL: File Access Methods
**Backend Path (WSL):** `\\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api`
**Frontend Path:** `C:\Users\tschi\src\Platform_DMS_8.4.25\Platform_DMS_8.4.25`

**Access:** Full read/write to both directories via filesystem tools.

**IMPORTANT:** Always use the `\\wsl.localhost\` prefix for WSL paths when using filesystem tools.

### Database: SQLite (Development & Test)
**CRITICAL SQLite Limitations:**
- ❌ NO `jsonb` type - use `t.text` instead
- ❌ NO native JSON support - use `serialize :field, coder: JSON` in models
- ✅ Use `t.text` for JSON fields, then serialize in model
- ✅ Test environment uses SQLite, production may use PostgreSQL

### Rails Environment
- **Development Port:** 3001 (NOT 3000)
- **Test Command:** `bundle exec rspec spec/path/to/spec.rb --format documentation`
- **Migration Command:** `bin/rails db:migrate RAILS_ENV=development`
- **Cache Required:** Run `bin/rails dev:cache` to enable caching (required for rate limiting)

### Model Requirements (From Existing Schema)
- **Lead:** requires `company_id` and `source_id` (NOT NULL)
- **Company:** only has `name` field (no subdomain, status, etc.)
- **Source:** has `name`, `source_type`, `is_active`

### Common Issues to Avoid
1. **Always use `t.text` instead of `t.jsonb`** for SQLite compatibility
2. **Always include `serialize :field, coder: JSON`** in models for JSON fields
3. **Remember `bin/rails dev:cache`** to enable rate limiting
4. **Lead creation needs Company AND Source**
5. **Use proper WSL paths** with `\\wsl.localhost\` prefix
6. **Port 3001, not 3000**

---

## Phase 4A: Authentication System ✅ COMPLETE

### Summary
JWT-based authentication with password login, magic links, password reset, and rate limiting.

### What Was Built
1. **JWT Authentication System** (`lib/json_web_token.rb`)
   - 24-hour token expiration
   - Based on Rails secret_key_base

2. **Database Table:** `buyer_portal_accesses`
   ```ruby
   t.string :buyer_type, null: false          # Polymorphic
   t.integer :buyer_id, null: false           # Polymorphic
   t.string :email, null: false               # Unique, case-insensitive
   t.string :password_digest                  # BCrypt
   t.string :reset_token                      # Password reset
   t.datetime :reset_token_expires_at         # 1 hour expiration
   t.string :login_token                      # Magic link
   t.datetime :login_token_expires_at         # 15 min expiration
   t.datetime :last_login_at                  # Login tracking
   t.integer :login_count, default: 0         # Login tracking
   t.string :last_login_ip                    # Login tracking
   t.boolean :portal_enabled, default: true   # Enable/disable access
   t.boolean :email_opt_in, default: true     # Email preferences
   t.boolean :sms_opt_in, default: true       # SMS preferences
   t.boolean :marketing_opt_in, default: false # Marketing preferences
   t.text :preference_history                 # JSON text field (SQLite!)
   ```

3. **Model:** `app/models/buyer_portal_access.rb`
   - Polymorphic association to buyer (Lead/Account)
   - `has_secure_password` for authentication
   - Token generation methods
   - **CRITICAL:** `serialize :preference_history, coder: JSON`

4. **Controller:** `app/controllers/api/portal/auth_controller.rb`
   - POST `/api/portal/auth/login` - Email/password login
   - POST `/api/portal/auth/magic-link` - Request magic link
   - GET `/api/portal/auth/verify/:token` - Verify magic link
   - POST `/api/portal/auth/reset-password` - Request password reset
   - PATCH `/api/portal/auth/reset-password/:token` - Reset password
   - GET `/api/portal/auth/profile` - Get buyer profile (requires JWT)

5. **Application Controller Helpers**
   - `current_portal_buyer` - Extract buyer from JWT
   - `authenticate_portal_buyer!` - Enforce authentication
   - `authorize_buyer_resource!` - Ensure buyer owns resource

6. **Rate Limiting**
   - 5 attempts per 15 minutes per IP
   - Uses `Rails.cache` (requires `bin/rails dev:cache`)
   - Returns 429 Too Many Requests after limit

### Test Results
✅ **59/59 tests passing**
- JWT encoding/decoding: 8/8
- Model validations: 17/17
- Controller/API: 34/34

### API Testing
```bash
# Login
curl -X POST http://localhost:3001/api/portal/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com", "password": "Password123!"}'

# Profile (with JWT token)
curl -X GET http://localhost:3001/api/portal/auth/profile \
  -H "Authorization: Bearer YOUR_TOKEN_HERE"
```

### Test Credentials
- **Email:** testbuyer@example.com
- **Password:** Password123!

### Key Files
- `lib/json_web_token.rb`
- `app/models/buyer_portal_access.rb`
- `app/controllers/api/portal/auth_controller.rb`
- `db/migrate/20251013212455_create_buyer_portal_accesses.rb`
- All specs in `spec/`

---

## Phase 4B: Quote Management APIs

### Objective
Allow authenticated buyers to view, accept, and reject quotes through the portal.

### Prerequisites
- Phase 4A authentication completed
- Existing `quotes` table with:
  - `account_id`, `contact_id`, `customer_id`, `vehicle_id`
  - `quote_number`, `status`, `subtotal`, `tax`, `total`
  - `items` (JSON text field)
  - `valid_until`, `sent_at`, `viewed_at`, `accepted_at`, `rejected_at`
  - `notes`, `custom_fields` (JSON text field)

### Database Changes Needed

#### 1. Add Portal Visibility to Quotes
```ruby
# Migration: add_portal_fields_to_quotes
class AddPortalFieldsToQuotes < ActiveRecord::Migration[8.0]
  def change
    add_column :quotes, :portal_visible, :boolean, default: false
    add_column :quotes, :portal_message, :text
    add_column :quotes, :buyer_portal_access_id, :integer
    
    add_index :quotes, :portal_visible
    add_index :quotes, :buyer_portal_access_id
    add_foreign_key :quotes, :buyer_portal_accesses
  end
end
```

### API Endpoints to Build

#### 1. List Quotes
**Endpoint:** `GET /api/portal/quotes`  
**Auth:** Required (JWT)  
**Description:** List all quotes visible to authenticated buyer

**Query Parameters:**
- `status` - Filter by status (draft, sent, viewed, accepted, rejected)
- `page` - Pagination (default: 1)
- `per_page` - Items per page (default: 20)

**Response:**
```json
{
  "ok": true,
  "quotes": [
    {
      "id": 1,
      "quote_number": "Q-2025-0001",
      "status": "sent",
      "subtotal": "1299.99",
      "tax": "130.00",
      "total": "1429.99",
      "valid_until": "2025-11-01",
      "sent_at": "2025-10-01T10:00:00Z",
      "viewed_at": null,
      "items_count": 3,
      "portal_message": "Thanks for your interest!"
    }
  ],
  "pagination": {
    "current_page": 1,
    "total_pages": 1,
    "total_count": 1,
    "per_page": 20
  }
}
```

#### 2. View Quote Details
**Endpoint:** `GET /api/portal/quotes/:id`  
**Auth:** Required (JWT)  
**Description:** View full details of a specific quote

**Response:**
```json
{
  "ok": true,
  "quote": {
    "id": 1,
    "quote_number": "Q-2025-0001",
    "status": "sent",
    "subtotal": "1299.99",
    "tax": "130.00",
    "total": "1429.99",
    "valid_until": "2025-11-01",
    "sent_at": "2025-10-01T10:00:00Z",
    "viewed_at": "2025-10-14T10:00:00Z",
    "items": [
      {
        "description": "Oil Change",
        "quantity": 1,
        "unit_price": "49.99",
        "total": "49.99"
      },
      {
        "description": "Tire Rotation",
        "quantity": 1,
        "unit_price": "30.00",
        "total": "30.00"
      }
    ],
    "notes": "Please call to schedule",
    "portal_message": "Thanks for your interest!",
    "custom_fields": {}
  }
}
```

**Side Effect:** First view records `viewed_at` timestamp

#### 3. Accept Quote
**Endpoint:** `POST /api/portal/quotes/:id/accept`  
**Auth:** Required (JWT)  
**Description:** Accept a quote

**Request Body:**
```json
{
  "acceptance_notes": "Looking forward to it!"
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
    "accepted_at": "2025-10-14T10:30:00Z"
  }
}
```

**Validations:**
- Quote must be in "sent" or "viewed" status
- Quote must not be expired (`valid_until` >= today)
- Quote must belong to authenticated buyer

#### 4. Reject Quote
**Endpoint:** `POST /api/portal/quotes/:id/reject`  
**Auth:** Required (JWT)  
**Description:** Reject a quote

**Request Body:**
```json
{
  "rejection_reason": "Found a better price elsewhere"
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
    "rejected_at": "2025-10-14T10:30:00Z"
  }
}
```

### Controller Structure
```ruby
# app/controllers/api/portal/quotes_controller.rb
module Api
  module Portal
    class QuotesController < ApplicationController
      before_action :authenticate_portal_buyer!
      before_action :set_quote, only: [:show, :accept, :reject]
      before_action :authorize_buyer_resource!, only: [:show, :accept, :reject]
      
      def index
        # List quotes for buyer
      end
      
      def show
        # View quote details, record viewed_at
      end
      
      def accept
        # Accept quote
      end
      
      def reject
        # Reject quote
      end
      
      private
      
      def set_quote
        @quote = Quote.find(params[:id])
      end
      
      def quote_params
        params.permit(:acceptance_notes, :rejection_reason)
      end
    end
  end
end
```

### Model Updates
```ruby
# app/models/quote.rb
class Quote < ApplicationRecord
  belongs_to :buyer_portal_access, optional: true
  
  # Use serialize for JSON fields (SQLite compatibility)
  serialize :items, coder: JSON
  serialize :custom_fields, coder: JSON
  
  # Scopes
  scope :portal_visible, -> { where(portal_visible: true) }
  scope :for_buyer, ->(buyer_access) { 
    where(buyer_portal_access_id: buyer_access.id) 
  }
  
  # State transitions
  def can_accept?
    ['sent', 'viewed'].include?(status) && !expired?
  end
  
  def can_reject?
    ['sent', 'viewed'].include?(status) && !expired?
  end
  
  def expired?
    valid_until && valid_until < Date.today
  end
  
  def accept!(notes: nil)
    return false unless can_accept?
    
    update!(
      status: 'accepted',
      accepted_at: Time.current,
      notes: [notes, self.notes].compact.join("\n")
    )
  end
  
  def reject!(reason: nil)
    return false unless can_reject?
    
    update!(
      status: 'rejected',
      rejected_at: Time.current,
      notes: [reason, self.notes].compact.join("\n")
    )
  end
  
  def record_view!
    update!(viewed_at: Time.current) unless viewed_at
  end
end
```

### Routes
```ruby
# config/routes.rb
namespace :api do
  namespace :portal do
    # Auth routes (from Phase 4A)
    post 'auth/login', to: 'auth#login'
    # ... other auth routes
    
    # Quote routes (Phase 4B)
    resources :quotes, only: [:index, :show] do
      member do
        post :accept
        post :reject
      end
    end
  end
end
```

### Testing Strategy

#### RSpec Tests
```ruby
# spec/controllers/api/portal/quotes_controller_spec.rb
require 'rails_helper'

RSpec.describe Api::Portal::QuotesController, type: :controller do
  let(:company) { create(:company) }
  let(:source) { create(:source) }
  let(:lead) { create(:lead, company: company, source: source) }
  let(:buyer_access) { create(:buyer_portal_access, buyer: lead) }
  let(:account) { create(:account, company: company) }
  let(:quote) { create(:quote, account: account, buyer_portal_access: buyer_access, portal_visible: true) }
  
  before do
    token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
    request.headers['Authorization'] = "Bearer #{token}"
  end
  
  describe 'GET #index' do
    it 'returns list of quotes' do
      get :index
      expect(response).to have_http_status(:ok)
      # ... assertions
    end
  end
  
  describe 'GET #show' do
    it 'returns quote details' do
      get :show, params: { id: quote.id }
      expect(response).to have_http_status(:ok)
      # ... assertions
    end
    
    it 'records viewed_at on first view' do
      expect {
        get :show, params: { id: quote.id }
        quote.reload
      }.to change { quote.viewed_at }.from(nil)
    end
  end
  
  describe 'POST #accept' do
    it 'accepts a valid quote' do
      post :accept, params: { id: quote.id, acceptance_notes: 'Great!' }
      expect(response).to have_http_status(:ok)
      quote.reload
      expect(quote.status).to eq('accepted')
    end
    
    it 'rejects expired quotes' do
      quote.update!(valid_until: 1.day.ago)
      post :accept, params: { id: quote.id }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
  
  describe 'POST #reject' do
    it 'rejects a valid quote' do
      post :reject, params: { id: quote.id, rejection_reason: 'Too expensive' }
      expect(response).to have_http_status(:ok)
      quote.reload
      expect(quote.status).to eq('rejected')
    end
  end
end
```

### Manual Testing
```bash
# Get JWT token first
TOKEN=$(curl -s -X POST http://localhost:3001/api/portal/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com", "password": "Password123!"}' | jq -r '.token')

# List quotes
curl -X GET http://localhost:3001/api/portal/quotes \
  -H "Authorization: Bearer $TOKEN" | jq '.'

# View quote details
curl -X GET http://localhost:3001/api/portal/quotes/1 \
  -H "Authorization: Bearer $TOKEN" | jq '.'

# Accept quote
curl -X POST http://localhost:3001/api/portal/quotes/1/accept \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"acceptance_notes": "Looking forward to it!"}' | jq '.'

# Reject quote
curl -X POST http://localhost:3001/api/portal/quotes/1/reject \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"rejection_reason": "Too expensive"}' | jq '.'
```

### Test Data Creation
```ruby
# create_test_quote.rb
company = Company.first_or_create!(name: 'Test Company')
source = Source.first_or_create!(name: 'Buyer Portal', source_type: 'portal', is_active: true)
lead = Lead.find_or_create_by!(email: 'testbuyer@example.com') do |l|
  l.company = company
  l.source = source
  l.first_name = 'Test'
  l.last_name = 'Buyer'
  l.phone = '555-1234'
end
buyer_access = BuyerPortalAccess.find_or_create_by!(email: 'testbuyer@example.com') do |b|
  b.buyer = lead
  b.password = 'Password123!'
  b.portal_enabled = true
end
account = Account.find_or_create_by!(name: 'Test Account', company: company) do |a|
  a.status = 'active'
  a.email = 'testbuyer@example.com'
end
quote = Quote.create!(
  account: account,
  buyer_portal_access: buyer_access,
  quote_number: "Q-#{Date.today.year}-#{Quote.count + 1}".rjust(4, '0'),
  status: 'sent',
  subtotal: 1299.99,
  tax: 130.00,
  total: 1429.99,
  items: [
    { description: 'Oil Change', quantity: 1, unit_price: 49.99, total: 49.99 },
    { description: 'Tire Rotation', quantity: 1, unit_price: 30.00, total: 30.00 }
  ],
  valid_until: 30.days.from_now.to_date,
  sent_at: Time.current,
  portal_visible: true,
  portal_message: 'Thanks for your interest!'
)
puts "✅ Test quote created: #{quote.quote_number}"
```

---

## Phase 4C: Document Management

### Objective
Allow buyers to upload documents and view/download documents shared by the company.

### Prerequisites
- Active Storage configured
- Phase 4A authentication completed

### Database Changes

#### 1. Portal Documents Table
```ruby
# Migration: create_portal_documents
class CreatePortalDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :portal_documents do |t|
      t.references :buyer_portal_access, null: false, foreign_key: true
      t.string :title, null: false
      t.text :description
      t.string :document_type # 'buyer_upload', 'company_share'
      t.string :category # 'invoice', 'contract', 'photo', 'other'
      t.string :status, default: 'active' # 'active', 'archived'
      t.boolean :buyer_can_view, default: true
      t.boolean :company_can_view, default: true
      t.text :metadata # JSON text field (SQLite!)
      
      t.timestamps
    end
    
    add_index :portal_documents, :document_type
    add_index :portal_documents, :category
    add_index :portal_documents, :status
  end
end
```

### API Endpoints

#### 1. List Documents
**Endpoint:** `GET /api/portal/documents`  
**Auth:** Required (JWT)

**Query Parameters:**
- `document_type` - Filter by type
- `category` - Filter by category
- `page`, `per_page` - Pagination

#### 2. Upload Document
**Endpoint:** `POST /api/portal/documents`  
**Auth:** Required (JWT)  
**Content-Type:** `multipart/form-data`

**Request:**
```
title: "Vehicle Registration"
description: "My current registration"
category: "other"
file: [binary data]
```

#### 3. View Document Details
**Endpoint:** `GET /api/portal/documents/:id`  
**Auth:** Required (JWT)

#### 4. Download Document
**Endpoint:** `GET /api/portal/documents/:id/download`  
**Auth:** Required (JWT)  
**Returns:** Binary file data

#### 5. Delete Document (buyer uploads only)
**Endpoint:** `DELETE /api/portal/documents/:id`  
**Auth:** Required (JWT)

### Model
```ruby
# app/models/portal_document.rb
class PortalDocument < ApplicationRecord
  belongs_to :buyer_portal_access
  has_one_attached :file
  
  serialize :metadata, coder: JSON
  
  validates :title, presence: true
  validates :document_type, inclusion: { in: %w[buyer_upload company_share] }
  validates :file, presence: true
  
  scope :active, -> { where(status: 'active') }
  scope :buyer_uploads, -> { where(document_type: 'buyer_upload') }
  scope :company_shares, -> { where(document_type: 'company_share') }
  
  def buyer_owned?
    document_type == 'buyer_upload'
  end
  
  def file_size_human
    ActiveSupport::NumberHelper.number_to_human_size(file.byte_size)
  end
end
```

---

## Phase 4D: Communication Preferences

### Objective
Allow buyers to manage their communication preferences and view their preference history.

### API Endpoints

#### 1. Get Current Preferences
**Endpoint:** `GET /api/portal/preferences`  
**Auth:** Required (JWT)

**Response:**
```json
{
  "ok": true,
  "preferences": {
    "email_opt_in": true,
    "sms_opt_in": true,
    "marketing_opt_in": false
  },
  "history": [
    {
      "changed_at": "2025-10-14T10:00:00Z",
      "field": "marketing_opt_in",
      "old_value": true,
      "new_value": false
    }
  ]
}
```

#### 2. Update Preferences
**Endpoint:** `PATCH /api/portal/preferences`  
**Auth:** Required (JWT)

**Request:**
```json
{
  "email_opt_in": true,
  "sms_opt_in": false,
  "marketing_opt_in": false
}
```

**Response:**
```json
{
  "ok": true,
  "message": "Preferences updated successfully",
  "preferences": {
    "email_opt_in": true,
    "sms_opt_in": false,
    "marketing_opt_in": false
  }
}
```

### Controller
```ruby
# app/controllers/api/portal/preferences_controller.rb
module Api
  module Portal
    class PreferencesController < ApplicationController
      before_action :authenticate_portal_buyer!
      
      def show
        render json: {
          ok: true,
          preferences: {
            email_opt_in: current_portal_buyer.email_opt_in,
            sms_opt_in: current_portal_buyer.sms_opt_in,
            marketing_opt_in: current_portal_buyer.marketing_opt_in
          },
          history: current_portal_buyer.preference_history || []
        }
      end
      
      def update
        current_portal_buyer.update_preferences(preference_params)
        
        render json: {
          ok: true,
          message: 'Preferences updated successfully',
          preferences: {
            email_opt_in: current_portal_buyer.email_opt_in,
            sms_opt_in: current_portal_buyer.sms_opt_in,
            marketing_opt_in: current_portal_buyer.marketing_opt_in
          }
        }
      end
      
      private
      
      def preference_params
        params.permit(:email_opt_in, :sms_opt_in, :marketing_opt_in)
      end
    end
  end
end
```

### Model Method
```ruby
# app/models/buyer_portal_access.rb
def update_preferences(new_prefs)
  changes = []
  
  %i[email_opt_in sms_opt_in marketing_opt_in].each do |field|
    if new_prefs.key?(field) && new_prefs[field] != send(field)
      changes << {
        changed_at: Time.current,
        field: field,
        old_value: send(field),
        new_value: new_prefs[field]
      }
      send("#{field}=", new_prefs[field])
    end
  end
  
  if changes.any?
    self.preference_history ||= []
    self.preference_history += changes
    save!
  end
end
```

---

## Phase 4E: Profile Management

### Objective
Allow buyers to update their contact information and change their password.

### API Endpoints

#### 1. Update Profile
**Endpoint:** `PATCH /api/portal/profile`  
**Auth:** Required (JWT)

**Request:**
```json
{
  "phone": "555-9999",
  "email": "newemail@example.com"
}
```

**Response:**
```json
{
  "ok": true,
  "message": "Profile updated successfully",
  "buyer": {
    "email": "newemail@example.com",
    "phone": "555-9999"
  }
}
```

#### 2. Change Password
**Endpoint:** `PATCH /api/portal/change-password`  
**Auth:** Required (JWT)

**Request:**
```json
{
  "current_password": "Password123!",
  "new_password": "NewPassword456!",
  "new_password_confirmation": "NewPassword456!"
}
```

**Response:**
```json
{
  "ok": true,
  "message": "Password changed successfully"
}
```

#### 3. Get Login History
**Endpoint:** `GET /api/portal/login-history`  
**Auth:** Required (JWT)

**Response:**
```json
{
  "ok": true,
  "login_history": {
    "login_count": 15,
    "last_login_at": "2025-10-14T10:00:00Z",
    "last_login_ip": "192.168.1.100"
  }
}
```

---

## Testing Strategy for All Phases

### Unit Tests (Models)
- Validations
- Associations
- Instance methods
- Class methods
- Scopes

### Controller Tests
- Authentication enforcement
- Authorization (buyer owns resource)
- Happy path scenarios
- Error handling
- Edge cases

### Integration Tests (if needed)
- Multi-step workflows
- Cross-controller interactions

### Manual API Testing
- cURL commands for each endpoint
- Postman collection (optional)
- Test data creation scripts

---

## Security Considerations

### Authentication
✅ JWT tokens with expiration  
✅ Rate limiting on login endpoints  
✅ Secure password hashing (bcrypt)

### Authorization
✅ `authenticate_portal_buyer!` on all protected endpoints  
✅ `authorize_buyer_resource!` ensures resource ownership  
✅ Check quote/document ownership before operations

### Data Privacy
✅ Buyers only see their own data  
✅ Email enumeration prevention  
✅ IP tracking for security monitoring

### File Upload Security (Phase 4C)
⚠️ Validate file types  
⚠️ Limit file sizes  
⚠️ Scan for malware (if possible)  
⚠️ Store files securely (Active Storage)

---

## Deployment Checklist

### Database
- [ ] Run all migrations in production
- [ ] Verify indexes are created
- [ ] Check foreign key constraints

### Environment
- [ ] Set `SECRET_KEY_BASE` for JWT
- [ ] Configure cache store (Redis recommended for production)
- [ ] Set proper CORS headers if frontend is on different domain
- [ ] Configure Active Storage for production (S3, etc.)

### Security
- [ ] Enable HTTPS
- [ ] Set secure cookie flags
- [ ] Configure rate limiting thresholds
- [ ] Set up monitoring for failed auth attempts

### Testing
- [ ] Run full test suite
- [ ] Manual API testing in staging
- [ ] Load testing for rate limiting
- [ ] Test file uploads with various file types

---

## File Structure Summary

```
app/
├── controllers/
│   ├── application_controller.rb          # Auth helpers
│   └── api/
│       └── portal/
│           ├── auth_controller.rb         # Phase 4A ✅
│           ├── quotes_controller.rb       # Phase 4B
│           ├── documents_controller.rb    # Phase 4C
│           ├── preferences_controller.rb  # Phase 4D
│           └── profile_controller.rb      # Phase 4E
├── models/
│   ├── buyer_portal_access.rb            # Phase 4A ✅
│   ├── quote.rb                           # Updated Phase 4B
│   └── portal_document.rb                 # Phase 4C
├── services/
│   └── buyer_portal_service.rb           # Email notifications
└── lib/
    └── json_web_token.rb                  # Phase 4A ✅

db/
└── migrate/
    ├── 20251013212455_create_buyer_portal_accesses.rb  # Phase 4A ✅
    ├── YYYYMMDDHHMMSS_add_portal_fields_to_quotes.rb   # Phase 4B
    └── YYYYMMDDHHMMSS_create_portal_documents.rb       # Phase 4C

spec/
├── controllers/
│   └── api/
│       └── portal/
│           ├── auth_controller_spec.rb    # Phase 4A ✅
│           ├── quotes_controller_spec.rb  # Phase 4B
│           └── ...
├── models/
│   ├── buyer_portal_access_spec.rb        # Phase 4A ✅
│   ├── quote_spec.rb
│   └── portal_document_spec.rb
└── factories/
    ├── buyer_portal_accesses.rb           # Phase 4A ✅
    ├── quotes.rb
    └── portal_documents.rb
```

---

## Quick Commands Reference

```bash
# Migration
bin/rails db:migrate RAILS_ENV=development

# Enable caching (required for rate limiting)
bin/rails dev:cache

# Run tests
bundle exec rspec spec/controllers/api/portal/ --format documentation

# Create test data
bundle exec rails runner create_test_buyer.rb
bundle exec rails runner create_test_quote.rb

# Start server
bundle exec rails s -p 3001

# Test API
TOKEN=$(curl -s -X POST http://localhost:3001/api/portal/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "testbuyer@example.com", "password": "Password123!"}' | jq -r '.token')

curl -X GET http://localhost:3001/api/portal/quotes \
  -H "Authorization: Bearer $TOKEN" | jq '.'
```

---

## Critical Reminders for Implementation

1. **Always use `t.text` for JSON fields in migrations**
2. **Always add `serialize :field, coder: JSON` in models**
3. **Use WSL paths with `\\wsl.localhost\` prefix**
4. **Lead requires company_id AND source_id**
5. **Port 3001, not 3000**
6. **Enable caching: `bin/rails dev:cache`**
7. **Test with JWT token from login**
8. **Check authorization on all protected endpoints**
9. **Record timestamps (viewed_at, accepted_at, etc.)**
10. **Return consistent JSON response format**

---

## Success Criteria

### Phase 4A ✅
- [x] JWT authentication working
- [x] All auth endpoints functional
- [x] Rate limiting active
- [x] 59/59 tests passing

### Phase 4B
- [ ] Quote list API working
- [ ] Quote details API working
- [ ] Accept/reject functionality working
- [ ] viewed_at timestamp recording
- [ ] Authorization checks passing
- [ ] All tests passing

### Phase 4C
- [ ] Document upload working
- [ ] Document list/download working
- [ ] File size limits enforced
- [ ] Authorization checks passing
- [ ] All tests passing

### Phase 4D
- [ ] Preference viewing working
- [ ] Preference updates working
- [ ] History tracking working
- [ ] All tests passing

### Phase 4E
- [ ] Profile updates working
- [ ] Password change working
- [ ] Login history working
- [ ] All tests passing

---

**Ready to implement Phase 4B - Quote Management!**
