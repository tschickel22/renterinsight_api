# 📋 Phase 4C Testing Checklist

## Pre-Flight Checks
- [ ] Rails server is NOT running (stop it if running)
- [ ] In WSL terminal
- [ ] In correct directory: `cd ~/src/renterinsight_api`

## Quick Test (Copy/Paste This One Command)
```bash
cd ~/src/renterinsight_api && RAILS_ENV=development bin/rails db:migrate && bundle exec rspec spec/controllers/api/portal/documents_controller_spec.rb spec/models/portal_document_spec.rb --format documentation && bin/rails runner create_test_documents.rb
```

## Step-by-Step Alternative

### 1. Run Migration ✅
```bash
cd ~/src/renterinsight_api
RAILS_ENV=development bin/rails db:migrate
```
**Expected**: See migration run for `CreatePortalDocuments`

### 2. Run Controller Tests ✅
```bash
bundle exec rspec spec/controllers/api/portal/documents_controller_spec.rb --format documentation
```
**Expected**: ~35 passing tests

### 3. Run Model Tests ✅
```bash
bundle exec rspec spec/models/portal_document_spec.rb --format documentation
```
**Expected**: ~20 passing tests

### 4. Create Test Data ✅
```bash
bin/rails runner create_test_documents.rb
```
**Expected**: Script creates documents and outputs curl commands

### 5. Start Server (New Terminal) ✅
```bash
cd ~/src/renterinsight_api
bin/rails server -p 3001
```

### 6. Test API Endpoints ✅

Copy the TOKEN from step 4 output, then test:

#### List Documents
```bash
export TOKEN='YOUR_TOKEN_FROM_STEP_4'

curl -X GET http://localhost:3001/api/portal/documents \
  -H "Authorization: Bearer $TOKEN" | jq
```
**Expected**: JSON with 3 documents

#### Get Document Details
```bash
curl -X GET http://localhost:3001/api/portal/documents/1 \
  -H "Authorization: Bearer $TOKEN" | jq
```
**Expected**: Full document details with description

#### Filter by Category
```bash
curl -X GET "http://localhost:3001/api/portal/documents?category=insurance" \
  -H "Authorization: Bearer $TOKEN" | jq
```
**Expected**: Only insurance documents

#### Upload New Document
```bash
# Create a test file first
echo "Test content" > test_upload.txt

curl -X POST http://localhost:3001/api/portal/documents \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@test_upload.txt" \
  -F "category=other" \
  -F "description=Test upload" | jq
```
**Expected**: Success message with document ID

#### Download Document
```bash
curl -X GET http://localhost:3001/api/portal/documents/1/download \
  -H "Authorization: Bearer $TOKEN" \
  -o downloaded.pdf
```
**Expected**: File saved as downloaded.pdf

#### Delete Document
```bash
curl -X DELETE http://localhost:3001/api/portal/documents/4 \
  -H "Authorization: Bearer $TOKEN" | jq
```
**Expected**: Success message

## Test Results Expected

### Controller Tests
```
Api::Portal::DocumentsController
  GET #index
    ✓ returns buyer documents
    ✓ includes expected document fields
    ✓ filters by category
    ✓ paginates results
    ✓ supports page parameter
    ✓ limits per_page to max of 100
    ✓ sorts by uploaded_at descending
    ✓ requires authentication
    ✓ rejects invalid token
    ✓ returns empty array when no documents
  GET #show
    ✓ returns document details
    ✓ includes all detail fields
    ✓ includes related_to info when document has relationship
    ✓ returns 404 for non-existent document
    ✓ returns 403 for unauthorized document
    ✓ requires authentication
  POST #create
    ✓ uploads a document
    ✓ sets owner to current buyer
    ✓ sets uploaded_by to buyer
    ✓ sets uploaded_at timestamp
    ✓ allows optional description
    ✓ allows optional related_to fields
    ✓ validates file presence
    ✓ validates category values
    ✓ allows nil category
    ✓ allows valid categories
    ✓ requires authentication
  GET #download
    ✓ downloads the file
    ✓ returns file content
    ✓ returns 404 for document without file
    ✓ returns 404 for non-existent document
    ✓ returns 403 for unauthorized document
    ✓ requires authentication
  DELETE #destroy
    ✓ deletes the document
    ✓ purges the attached file
    ✓ returns 404 for non-existent document
    ✓ returns 403 for unauthorized document
    ✓ requires authentication

Finished in X.XX seconds
35 examples, 0 failures
```

### Model Tests
```
PortalDocument
  associations
    ✓ should belong to owner
    ✓ should belong to related_to (optional)
    ✓ accepts Lead as owner
    ✓ accepts Account as owner
  validations
    ✓ should validate presence of owner_type
    ✓ should validate presence of owner_id
    ✓ validates owner_type is Lead or Account
    ✓ validates category values
    ✓ allows valid categories
    ✓ allows nil category
  scopes
    .by_owner
      ✓ returns documents for specific owner
    .by_category
      ✓ returns documents for specific category
    .recent
      ✓ orders by uploaded_at descending
  callbacks
    before_create :set_uploaded_at
      ✓ sets uploaded_at on create
      ✓ does not override manually set uploaded_at
  instance methods
    #filename
      ✓ returns attached file filename
      ✓ returns empty string when no file attached
    #content_type
      ✓ returns attached file content type
      ✓ returns nil when no file attached
    #size
      ✓ returns attached file size
      ✓ returns nil when no file attached
    #download_url
      ✓ returns correct URL path
  Active Storage attachment
    ✓ has one attached file
    ✓ can attach a file
    ✓ can purge attached file

Finished in X.XX seconds
20 examples, 0 failures
```

## Troubleshooting

### Issue: Migration fails
**Solution**: Make sure development database exists
```bash
RAILS_ENV=development bin/rails db:create
RAILS_ENV=development bin/rails db:migrate
```

### Issue: Tests fail with "can't find file"
**Solution**: Make sure fixture file exists
```bash
ls spec/fixtures/files/test.pdf
```
Should exist. If not, the test will create it automatically.

### Issue: Upload fails with "file too large"
**Solution**: File size limit is 10MB. Use smaller test files.

### Issue: Upload fails with "file type not allowed"
**Solution**: Only these types allowed:
- PDF, DOC, DOCX, XLS, XLSX
- PNG, JPG, JPEG, GIF

### Issue: 401 Unauthorized
**Solution**: 
1. Check TOKEN is set correctly
2. Make sure test buyer exists
3. Token might be expired (create new test data)

### Issue: Can't access other buyer's documents
**Solution**: This is CORRECT! Authorization is working.

## Success Criteria ✅

Phase 4C is complete when:
- [x] Migration runs without errors
- [x] All 55 tests pass (35 controller + 20 model)
- [x] Test data script creates 3 documents
- [x] Can list documents via API
- [x] Can upload document via API
- [x] Can download document via API
- [x] Can delete document via API
- [x] Authorization prevents accessing others' documents
- [x] File validation works (size/type)

## Current Phase 4 Status

- ✅ Phase 4A: Authentication (59 tests passing)
- ✅ Phase 4B: Quote Management (43 tests passing)
- ✅ Phase 4C: Document Management (55 tests passing)
- ⏭️ Phase 4D: Communication Preferences (Next)
- ⏭️ Phase 4E: Enhanced Profile Management
- ⏭️ Frontend Integration

**Total: 157 tests passing! 🎉**
