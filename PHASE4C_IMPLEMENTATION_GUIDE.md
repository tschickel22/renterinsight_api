# Phase 4C: Document Management - Complete Implementation Guide

## Context for New Chat Session

### Project Structure
- **Backend Path:** `\\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api`
- **Frontend Path:** `C:\Users\tschi\src\Platform_DMS_8.4.25\Platform_DMS_8.4.25`
- **Access:** Use WSL paths with `\\wsl.localhost\` prefix for file operations
- **Server Port:** 3001 (not 3000)

---

## Phase 4 Progress Summary

### ✅ Phase 4A: Authentication (COMPLETE)
- JWT-based authentication
- Login, magic link, password reset
- 59/59 tests passing
- **Test Credentials:** testbuyer@example.com / Password123!

### ✅ Phase 4B: Quote Management (COMPLETE)
- 4 API endpoints (list, show, accept, reject)
- 43/43 tests passing
- Pagination, filtering, auto-viewed tracking
- Activity notes on accept/reject
- **Files:**
  - `app/controllers/api/portal/quotes_controller.rb`
  - `app/services/quote_presenter.rb`
  - Complete test suite

### 🎯 Phase 4C: Document Management (CURRENT)
**Objective:** Allow buyers to upload and view documents related to their quotes/account

---

## Critical Lessons Learned (MUST FOLLOW!)

### 1. SQLite Compatibility - NEVER use jsonb!
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

### 2. Database Operations
```bash
# Always migrate development database explicitly:
cd ~/src/renterinsight_api && bin/rails db:migrate RAILS_ENV=development

# Test database migrates automatically when running specs
```

### 3. Caching Must Be Enabled
```bash
# Required for rate limiting and cache-dependent features:
bin/rails dev:cache

# Verify cache is working:
bin/rails runner "
puts 'Cache: ' + Rails.cache.class.to_s
Rails.cache.write('test', 'value')
puts Rails.cache.read('test').inspect
"
```

### 4. Model Validations & Callbacks
- **Quote model** has `before_validation` callbacks that recalculate totals from items
- When creating test data with past dates, use `update_column(:field, value)` to bypass validations
- Always check model validations before creating test records

### 5. Test Data Creation Pattern
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

### 6. File Access Patterns
```ruby
# Reading files - use Filesystem tool with WSL path:
Filesystem:read_file("\\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api\app\models\lead.rb")

# Writing files - same WSL path:
Filesystem:write_file("\\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api\test_script.rb")
```

### 7. Controller Pattern (Follow This!)
```ruby
module Api
  module Portal
    class ResourceController < ApplicationController
      skip_before_action :authenticate  # Skip default auth
      before_action :authenticate_portal_buyer!  # Use portal auth
      before_action :set_resource, only: [:show, :update, :destroy]
      before_action :authorize_resource!, only: [:show, :update, :destroy]
      
      def index
        resources = buyer_resources
        render json: { ok: true, resources: resources }
      end
      
      private
      
      def buyer_resources
        # Filter resources by current buyer
        buyer = current_portal_buyer.buyer
        case buyer
        when Lead
          # Lead logic
        when Account
          # Account logic
        end
      end
      
      def authorize_resource!
        # Check ownership
        unless owner_matches?
          render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
        end
      end
    end
  end
end
```

### 8. JSON Response Format (Be Consistent!)
```ruby
# Success:
{ ok: true, data: {...} }

# Error:
{ ok: false, error: "Error message" }

# With validation errors:
{ ok: false, error: "Error message", errors: [...] }
```

---

## Phase 4C: Document Management

### Objective
Allow buyers to upload, view, download, and delete documents related to their account/quotes.

### Prerequisites
- Phase 4A complete (authentication working)
- Phase 4B complete (quotes working)
- Active Storage configured in Rails

---

## Required Endpoints

### 1. List Documents
**GET** `/api/portal/documents`

**Authentication:** Required (JWT)

**Query Parameters:**
- `category` (optional) - filter by category
- `page` (optional) - pagination
- `per_page` (optional) - items per page (default: 20, max: 100)

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
      "category": "insurance",
      "uploaded_at": "2025-10-15T10:00:00Z",
      "uploaded_by": "buyer",
      "url": "/api/portal/documents/1/download"
    }
  ],
  "pagination": {
    "current_page": 1,
    "total_pages": 1,
    "total_count": 3,
    "per_page": 20
  }
}
```

**Business Rules:**
- Only show documents owned by buyer
- Support categories: insurance, registration, invoice, receipt, other
- Default sort: newest first (uploaded_at DESC)

---

### 2. Show Document Details
**GET** `/api/portal/documents/:id`

**Authentication:** Required (JWT)

**Response:**
```json
{
  "ok": true,
  "document": {
    "id": 1,
    "filename": "insurance_card.pdf",
    "content_type": "application/pdf",
    "size": 245632,
    "category": "insurance",
    "description": "Current insurance card",
    "uploaded_at": "2025-10-15T10:00:00Z",
    "uploaded_by": "buyer",
    "url": "/api/portal/documents/1/download",
    "related_to": {
      "type": "Quote",
      "id": 5,
      "reference": "Q-2025-001"
    }
  }
}
```

**Business Rules:**
- Only accessible by document owner
- Return 404 for non-existent or unauthorized documents

---

### 3. Upload Document
**POST** `/api/portal/documents`

**Authentication:** Required (JWT)

**Request:** multipart/form-data
```
file: [binary file data]
category: "insurance"  (optional)
description: "2024 insurance card"  (optional)
related_to_type: "Quote"  (optional)
related_to_id: 5  (optional)
```

**Response:**
```json
{
  "ok": true,
  "message": "Document uploaded successfully",
  "document": {
    "id": 1,
    "filename": "insurance_card.pdf",
    "content_type": "application/pdf",
    "size": 245632,
    "category": "insurance",
    "url": "/api/portal/documents/1/download"
  }
}
```

**Business Rules:**
- Max file size: 10MB
- Allowed types: PDF, PNG, JPG, JPEG, GIF, DOC, DOCX, XLS, XLSX
- Store in Active Storage
- Associate with buyer's account/lead
- Track who uploaded (buyer vs staff)

**Validation Errors:**
```json
{
  "ok": false,
  "error": "File validation failed",
  "errors": [
    "File is too large (max 10MB)",
    "File type not allowed"
  ]
}
```

---

### 4. Download Document
**GET** `/api/portal/documents/:id/download`

**Authentication:** Required (JWT)

**Response:** Binary file data with appropriate headers
```
Content-Type: application/pdf
Content-Disposition: attachment; filename="insurance_card.pdf"
Content-Length: 245632
```

**Business Rules:**
- Only accessible by document owner
- Stream file directly (don't load into memory)
- Return 404 for non-existent or unauthorized documents

---

### 5. Delete Document
**DELETE** `/api/portal/documents/:id`

**Authentication:** Required (JWT)

**Response:**
```json
{
  "ok": true,
  "message": "Document deleted successfully"
}
```

**Business Rules:**
- Only allow deletion by document owner
- Use Active Storage's purge method
- Return 404 for non-existent documents
- Return 403 for unauthorized deletion attempts

---

## Implementation Steps

### Step 1: Check Active Storage Configuration

```bash
# Check if Active Storage is installed
cd ~/src/renterinsight_api
grep -r "ActiveStorage" config/

# If not installed, run:
bin/rails active_storage:install
bin/rails db:migrate RAILS_ENV=development
```

### Step 2: Create PortalDocument Model

**Migration:**
```ruby
class CreatePortalDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :portal_documents do |t|
      # Polymorphic association to buyer
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      
      # Document metadata
      t.string :category
      t.text :description
      
      # Optional relationship to other records (Quote, etc)
      t.string :related_to_type
      t.bigint :related_to_id
      
      # Tracking
      t.string :uploaded_by, default: 'buyer'  # 'buyer' or 'staff'
      t.datetime :uploaded_at
      
      t.timestamps
      
      t.index [:owner_type, :owner_id], name: 'index_portal_documents_on_owner'
      t.index [:related_to_type, :related_to_id], name: 'index_portal_documents_on_related_to'
      t.index :category
      t.index :uploaded_at
    end
  end
end
```

**Model:** `app/models/portal_document.rb`
```ruby
# frozen_string_literal: true

class PortalDocument < ApplicationRecord
  # Active Storage attachment
  has_one_attached :file
  
  # Polymorphic associations
  belongs_to :owner, polymorphic: true
  belongs_to :related_to, polymorphic: true, optional: true
  
  # Validations
  validates :owner_type, presence: true, inclusion: { in: %w[Lead Account] }
  validates :owner_id, presence: true
  validates :category, inclusion: { 
    in: %w[insurance registration invoice receipt other], 
    allow_nil: true 
  }
  validates :file, presence: true, on: :create
  
  # Custom validation for file
  validate :acceptable_file, on: :create
  
  # Scopes
  scope :by_owner, ->(owner) { where(owner: owner) }
  scope :by_category, ->(category) { where(category: category) }
  scope :recent, -> { order(uploaded_at: :desc) }
  
  # Callbacks
  before_create :set_uploaded_at
  
  # File type validation
  ALLOWED_CONTENT_TYPES = %w[
    application/pdf
    image/png
    image/jpeg
    image/jpg
    image/gif
    application/msword
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  ].freeze
  
  MAX_FILE_SIZE = 10.megabytes
  
  # Instance methods
  def filename
    file.filename.to_s if file.attached?
  end
  
  def content_type
    file.content_type if file.attached?
  end
  
  def size
    file.byte_size if file.attached?
  end
  
  def download_url
    "/api/portal/documents/#{id}/download"
  end
  
  private
  
  def acceptable_file
    return unless file.attached?
    
    unless file.byte_size <= MAX_FILE_SIZE
      errors.add(:file, "is too large (max #{MAX_FILE_SIZE / 1.megabyte}MB)")
    end
    
    unless ALLOWED_CONTENT_TYPES.include?(file.content_type)
      errors.add(:file, "type not allowed (#{file.content_type})")
    end
  end
  
  def set_uploaded_at
    self.uploaded_at ||= Time.current
  end
end
```

### Step 3: Create Documents Controller

**File:** `app/controllers/api/portal/documents_controller.rb`

```ruby
# frozen_string_literal: true

module Api
  module Portal
    class DocumentsController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!
      before_action :set_document, only: [:show, :download, :destroy]
      before_action :authorize_document!, only: [:show, :download, :destroy]
      
      # GET /api/portal/documents
      def index
        documents = buyer_documents
        
        # Filter by category if provided
        if params[:category].present?
          documents = documents.by_category(params[:category])
        end
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 20).to_i, 100].min
        
        total_count = documents.count
        total_pages = (total_count.to_f / per_page).ceil
        
        documents = documents.recent
                            .limit(per_page)
                            .offset((page - 1) * per_page)
        
        render json: {
          ok: true,
          documents: documents.map { |d| DocumentPresenter.list_json(d) },
          pagination: {
            current_page: page,
            total_pages: total_pages,
            total_count: total_count,
            per_page: per_page
          }
        }
      end
      
      # GET /api/portal/documents/:id
      def show
        render json: {
          ok: true,
          document: DocumentPresenter.detail_json(@document)
        }
      end
      
      # POST /api/portal/documents
      def create
        document = PortalDocument.new(document_params)
        document.owner = current_portal_buyer.buyer
        document.uploaded_by = 'buyer'
        
        if document.save
          render json: {
            ok: true,
            message: 'Document uploaded successfully',
            document: DocumentPresenter.list_json(document)
          }, status: :created
        else
          render json: {
            ok: false,
            error: 'Document upload failed',
            errors: document.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # GET /api/portal/documents/:id/download
      def download
        if @document.file.attached?
          send_data @document.file.download,
                    filename: @document.filename,
                    type: @document.content_type,
                    disposition: 'attachment'
        else
          render json: {
            ok: false,
            error: 'File not found'
          }, status: :not_found
        end
      end
      
      # DELETE /api/portal/documents/:id
      def destroy
        @document.file.purge if @document.file.attached?
        @document.destroy
        
        render json: {
          ok: true,
          message: 'Document deleted successfully'
        }
      end
      
      private
      
      def set_document
        @document = PortalDocument.find_by(id: params[:id])
        unless @document
          render json: { ok: false, error: 'Document not found' }, status: :not_found
        end
      end
      
      def authorize_document!
        buyer = current_portal_buyer.buyer
        
        unless @document.owner == buyer
          render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
        end
      end
      
      def buyer_documents
        PortalDocument.by_owner(current_portal_buyer.buyer)
      end
      
      def document_params
        params.permit(:file, :category, :description, :related_to_type, :related_to_id)
      end
    end
  end
end
```

### Step 4: Create Document Presenter

**File:** `app/services/document_presenter.rb`

```ruby
# frozen_string_literal: true

class DocumentPresenter
  def self.list_json(document)
    {
      id: document.id,
      filename: document.filename,
      content_type: document.content_type,
      size: document.size,
      category: document.category,
      uploaded_at: document.uploaded_at,
      uploaded_by: document.uploaded_by,
      url: document.download_url
    }
  end
  
  def self.detail_json(document)
    list_json(document).merge(
      description: document.description,
      related_to: related_to_info(document)
    )
  end
  
  private
  
  def self.related_to_info(document)
    return nil unless document.related_to.present?
    
    {
      type: document.related_to_type,
      id: document.related_to_id,
      reference: reference_for(document.related_to)
    }
  end
  
  def self.reference_for(related)
    case related
    when Quote
      related.quote_number
    else
      related.id.to_s
    end
  end
end
```

### Step 5: Add Routes

**File:** `config/routes.rb`

```ruby
# Add to portal namespace
namespace :api do
  namespace :portal do
    # Phase 4A - Authentication
    post 'auth/login', to: 'auth#login'
    # ... other auth routes
    
    # Phase 4B - Quote Management
    resources :quotes, only: [:index, :show] do
      member do
        post :accept
        post :reject
      end
    end
    
    # Phase 4C - Document Management
    resources :documents, only: [:index, :show, :create, :destroy] do
      member do
        get :download
      end
    end
  end
end
```

### Step 6: Write Comprehensive Tests

**File:** `spec/controllers/api/portal/documents_controller_spec.rb`

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::Portal::DocumentsController, type: :controller do
  let(:company) { Company.first_or_create!(name: 'Test Company') }
  let(:source) { Source.first_or_create!(name: 'Portal') { |s| s.is_active = true } }
  
  let(:lead) { Lead.create!(
    company: company,
    source: source,
    first_name: 'Test',
    last_name: 'Buyer',
    email: 'buyer@example.com',
    is_converted: true
  )}
  
  let(:account) { Account.create!(
    company: company,
    name: 'Test Account',
    email: 'buyer@example.com',
    status: 'active'
  )}
  
  let!(:buyer_access) { BuyerPortalAccess.create!(
    buyer: lead,
    email: 'buyer@example.com',
    password: 'Password123!',
    password_confirmation: 'Password123!'
  )}
  
  before do
    lead.update!(converted_account_id: account.id)
    token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
    request.headers['Authorization'] = "Bearer #{token}"
  end
  
  describe 'GET #index' do
    let!(:document1) { create_document(lead, 'doc1.pdf', 'insurance') }
    let!(:document2) { create_document(lead, 'doc2.pdf', 'registration') }
    let!(:other_doc) { create_document(account, 'other.pdf', 'insurance') }
    
    it 'returns buyer documents' do
      get :index
      
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be true
      expect(json['documents'].length).to eq(2)
    end
    
    it 'filters by category' do
      get :index, params: { category: 'insurance' }
      
      json = JSON.parse(response.body)
      expect(json['documents'].length).to eq(1)
      expect(json['documents'][0]['category']).to eq('insurance')
    end
    
    it 'includes pagination' do
      get :index, params: { per_page: 1 }
      
      json = JSON.parse(response.body)
      expect(json['pagination']['per_page']).to eq(1)
      expect(json['pagination']['total_count']).to eq(2)
    end
    
    it 'requires authentication' do
      request.headers['Authorization'] = nil
      get :index
      
      expect(response).to have_http_status(:unauthorized)
    end
  end
  
  describe 'GET #show' do
    let!(:document) { create_document(lead, 'test.pdf', 'insurance') }
    
    it 'returns document details' do
      get :show, params: { id: document.id }
      
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be true
      expect(json['document']['id']).to eq(document.id)
      expect(json['document']['filename']).to eq('test.pdf')
    end
    
    it 'returns 404 for non-existent document' do
      get :show, params: { id: 99999 }
      
      expect(response).to have_http_status(:not_found)
    end
    
    it 'returns 403 for unauthorized document' do
      other_lead = Lead.create!(
        company: company,
        source: source,
        first_name: 'Other',
        last_name: 'Buyer',
        email: 'other@example.com'
      )
      other_doc = create_document(other_lead, 'other.pdf', 'insurance')
      
      get :show, params: { id: other_doc.id }
      
      expect(response).to have_http_status(:forbidden)
    end
  end
  
  describe 'POST #create' do
    it 'uploads a document' do
      file = fixture_file_upload('test.pdf', 'application/pdf')
      
      expect {
        post :create, params: {
          file: file,
          category: 'insurance',
          description: 'Test document'
        }
      }.to change { PortalDocument.count }.by(1)
      
      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be true
      expect(json['message']).to eq('Document uploaded successfully')
    end
    
    it 'rejects files over 10MB' do
      # Test with oversized file
    end
    
    it 'rejects invalid file types' do
      # Test with .exe file
    end
  end
  
  describe 'GET #download' do
    let!(:document) { create_document(lead, 'test.pdf', 'insurance') }
    
    it 'downloads the file' do
      get :download, params: { id: document.id }
      
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to eq('application/pdf')
      expect(response.headers['Content-Disposition']).to include('test.pdf')
    end
  end
  
  describe 'DELETE #destroy' do
    let!(:document) { create_document(lead, 'test.pdf', 'insurance') }
    
    it 'deletes the document' do
      expect {
        delete :destroy, params: { id: document.id }
      }.to change { PortalDocument.count }.by(-1)
      
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be true
      expect(json['message']).to eq('Document deleted successfully')
    end
  end
  
  private
  
  def create_document(owner, filename, category)
    doc = PortalDocument.create!(
      owner: owner,
      category: category,
      uploaded_by: 'buyer'
    )
    
    # Attach a test file
    doc.file.attach(
      io: File.open(Rails.root.join('spec', 'fixtures', 'files', 'test.pdf')),
      filename: filename,
      content_type: 'application/pdf'
    )
    
    doc
  end
end
```

### Step 7: Create Test Data Script

**File:** `create_test_documents.rb`

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
# Create test documents for buyer portal testing

puts "🔧 Creating test data for Phase 4C - Document Management..."

# Find the test buyer from Phase 4A/4B
lead = Lead.find_by(email: 'testbuyer@example.com')

if lead.nil?
  puts "❌ Test buyer not found. Please run Phase 4A/4B setup first."
  exit 1
end

account = Account.find_by(id: lead.converted_account_id)

if account.nil?
  puts "❌ Test account not found. Please run Phase 4B setup first."
  exit 1
end

puts "✅ Found buyer: #{lead.first_name} #{lead.last_name} (#{lead.email})"
puts "✅ Account: #{account.name} (ID: #{account.id})"

# Create test documents
doc1 = PortalDocument.create!(
  owner: lead,
  category: 'insurance',
  description: 'Current insurance card',
  uploaded_by: 'buyer',
  uploaded_at: Time.current
)

# You'll need to attach actual files in a real scenario
# doc1.file.attach(io: File.open('path/to/file.pdf'), filename: 'insurance.pdf')

puts ""
puts "✅ Created test documents"
puts ""
puts "📋 Test endpoints:"
puts ""
puts "# List documents:"
puts "curl -X GET http://localhost:3001/api/portal/documents \\"
puts "  -H 'Authorization: Bearer YOUR_TOKEN'"
puts ""
puts "# Upload document:"
puts "curl -X POST http://localhost:3001/api/portal/documents \\"
puts "  -H 'Authorization: Bearer YOUR_TOKEN' \\"
puts "  -F 'file=@/path/to/file.pdf' \\"
puts "  -F 'category=insurance' \\"
puts "  -F 'description=My insurance card'"
puts ""
puts "✅ Phase 4C test data ready!"
```

---

## Testing Checklist

### Functionality Tests
- [ ] List documents returns only buyer's documents
- [ ] Category filtering works
- [ ] Pagination works correctly
- [ ] Show document returns full details
- [ ] Upload accepts valid files
- [ ] Upload rejects files over 10MB
- [ ] Upload rejects invalid file types
- [ ] Download streams file correctly
- [ ] Delete removes document and file
- [ ] Authorization prevents access to other documents

### Security Tests
- [ ] Requires JWT token
- [ ] Returns 401 without token
- [ ] Returns 403 for unauthorized documents
- [ ] File download requires authentication
- [ ] Cannot access other buyers' documents

### Edge Cases
- [ ] Handles missing files gracefully
- [ ] Validates file presence on upload
- [ ] Handles corrupted files
- [ ] Validates category values
- [ ] Handles deleted owner records

---

## Common Gotchas & Solutions

### Gotcha #1: Active Storage Not Configured
**Error:** `uninitialized constant ActiveStorage`

**Solution:**
```bash
bin/rails active_storage:install
bin/rails db:migrate RAILS_ENV=development
```

### Gotcha #2: File Too Large in Tests
**Error:** Tests failing with large file uploads

**Solution:** Use small test files in `spec/fixtures/files/`
```ruby
# Create a small PDF for testing
File.write(Rails.root.join('spec/fixtures/files/test.pdf'), 
           "%PDF-1.4\ntest content")
```

### Gotcha #3: Content Type Detection Issues
**Error:** Wrong content type detected

**Solution:** Explicitly set content_type when attaching:
```ruby
file.attach(
  io: file_io,
  filename: 'test.pdf',
  content_type: 'application/pdf'  # Explicit
)
```

### Gotcha #4: Memory Issues with Large Downloads
**Error:** Server runs out of memory

**Solution:** Stream files, don't load into memory:
```ruby
# ✅ Good - streams
send_data file.download, filename: filename

# ❌ Bad - loads into memory
data = file.download
render json: { data: Base64.encode64(data) }
```

---

## Quick Test Commands

```bash
# 1. Run migrations
cd ~/src/renterinsight_api
bin/rails db:migrate RAILS_ENV=development

# 2. Verify Active Storage
bin/rails runner "puts ActiveStorage::Blob.count"

# 3. Run tests
bundle exec rspec spec/controllers/api/portal/documents_controller_spec.rb

# 4. Create test data
bin/rails runner create_test_documents.rb

# 5. Test upload
curl -X POST http://localhost:3001/api/portal/documents \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@test.pdf" \
  -F "category=insurance"
```

---

## Success Criteria

Phase 4C is complete when:
- [ ] All 5 endpoints working (list, show, upload, download, delete)
- [ ] 25+ tests passing
- [ ] File upload works with size/type validation
- [ ] File download streams correctly
- [ ] Authorization working (can't access others' docs)
- [ ] Pagination working
- [ ] Category filtering working
- [ ] Active Storage integrated
- [ ] Test data script works

---

## Next Steps After Phase 4C

1. ✅ Verify all tests pass
2. ✅ Test file upload/download manually
3. ➡️ **Phase 4D:** Communication Preferences
4. ➡️ **Phase 4E:** Enhanced Profile Management
5. ➡️ **Connect Frontend:** Integrate UI with all backend APIs

---

## Files to Create/Modify

### New Files
- `db/migrate/YYYYMMDDHHMMSS_create_portal_documents.rb`
- `app/models/portal_document.rb`
- `app/controllers/api/portal/documents_controller.rb`
- `app/services/document_presenter.rb`
- `spec/controllers/api/portal/documents_controller_spec.rb`
- `spec/models/portal_document_spec.rb`
- `create_test_documents.rb`

### Modified Files
- `config/routes.rb` (add document routes)

---

## Estimated Complexity

- **Lines of Code:** ~800 lines
- **Test Coverage:** 25+ tests
- **Time Estimate:** 2-3 hours with careful testing
- **Difficulty:** Medium (file handling adds complexity)

---

**Ready to implement Phase 4C! 🚀**

*Remember: Follow the patterns from Phase 4B, use safety checks, and test incrementally!*
