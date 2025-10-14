# Phase 4B Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         BUYER PORTAL - PHASE 4B                      │
│                          Quote Management API                         │
└─────────────────────────────────────────────────────────────────────┘

┌──────────────┐
│   Frontend   │
│   (React)    │
└──────┬───────┘
       │ HTTP Request
       │ Authorization: Bearer <JWT>
       ▼
┌─────────────────────────────────────────────────────────────────────┐
│                           API LAYER                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌─────────────────────────────────────────────────────┐            │
│  │  ApplicationController                               │            │
│  │  ├── authenticate_portal_buyer!                      │            │
│  │  └── current_portal_buyer                            │            │
│  └────────────────┬────────────────────────────────────┘            │
│                   │                                                   │
│  ┌────────────────▼───────────────────────────────────┐             │
│  │  Api::Portal::QuotesController                      │             │
│  │                                                      │             │
│  │  ┌──────────────────────────────────────────────┐  │             │
│  │  │  GET /api/portal/quotes (index)              │  │             │
│  │  │  • Pagination (20/page, max 100)             │  │             │
│  │  │  • Status filtering                           │  │             │
│  │  │  • Ordered by newest first                    │  │             │
│  │  └──────────────────────────────────────────────┘  │             │
│  │                                                      │             │
│  │  ┌──────────────────────────────────────────────┐  │             │
│  │  │  GET /api/portal/quotes/:id (show)           │  │             │
│  │  │  • Full quote details                         │  │             │
│  │  │  • Auto-marks as "viewed"                     │  │             │
│  │  │  • Includes items, vehicle, account info      │  │             │
│  │  └──────────────────────────────────────────────┘  │             │
│  │                                                      │             │
│  │  ┌──────────────────────────────────────────────┐  │             │
│  │  │  POST /api/portal/quotes/:id/accept          │  │             │
│  │  │  • Validates status (sent/viewed only)       │  │             │
│  │  │  • Checks expiration                          │  │             │
│  │  │  • Creates activity note                      │  │             │
│  │  └──────────────────────────────────────────────┘  │             │
│  │                                                      │             │
│  │  ┌──────────────────────────────────────────────┐  │             │
│  │  │  POST /api/portal/quotes/:id/reject          │  │             │
│  │  │  • Validates status (sent/viewed only)       │  │             │
│  │  │  • Checks expiration                          │  │             │
│  │  │  • Creates activity note with reason          │  │             │
│  │  └──────────────────────────────────────────────┘  │             │
│  │                                                      │             │
│  └──────────────────────────────────────────────────────┘            │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                         SERVICE LAYER                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌─────────────────────────────────────────────────────┐            │
│  │  QuotePresenter                                      │            │
│  │  ├── basic_json(quote)      → List view             │            │
│  │  │   • id, quote_number, status                     │            │
│  │  │   • subtotal, tax, total                         │            │
│  │  │   • timestamps                                   │            │
│  │  │                                                   │            │
│  │  └── detailed_json(quote)   → Detail view           │            │
│  │      • Everything from basic_json                   │            │
│  │      • items array (formatted)                      │            │
│  │      • notes, custom_fields                         │            │
│  │      • vehicle_info, account_info                   │            │
│  └─────────────────────────────────────────────────────┘            │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                         DATA LAYER                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐   │
│  │ BuyerPortalAccess│  │      Quote       │  │      Note       │   │
│  ├──────────────────┤  ├──────────────────┤  ├─────────────────┤   │
│  │ • buyer (poly)   │  │ • account_id     │  │ • entity (poly) │   │
│  │ • email          │  │ • status         │  │ • content       │   │
│  │ • password_digest│  │ • subtotal, tax  │  │ • created_by    │   │
│  │ • tokens         │  │ • items (JSON)   │  │ • timestamps    │   │
│  └────────┬─────────┘  │ • timestamps     │  └─────────────────┘   │
│           │            │ • is_deleted     │                         │
│           │            └──────────────────┘                         │
│           │                                                          │
│           │                                                          │
│  ┌────────▼─────────┐  ┌──────────────────┐                        │
│  │       Lead       │  │     Account      │                         │
│  ├──────────────────┤  ├──────────────────┤                         │
│  │ • email          │  │ • name           │                         │
│  │ • first_name     │  │ • email          │                         │
│  │ • last_name      │  │ • status         │                         │
│  │ • is_converted   │  │ • company_id     │                         │
│  │ • converted_     │  └──────────────────┘                         │
│  │   account_id     │                                                │
│  └──────────────────┘                                                │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                      AUTHORIZATION FLOW                               │
└─────────────────────────────────────────────────────────────────────┘

Request with JWT Token
    │
    ▼
┌────────────────────────────────┐
│ authenticate_portal_buyer!     │
│ • Decode JWT                   │
│ • Find BuyerPortalAccess       │
│ • Set current_portal_buyer     │
└────────────┬───────────────────┘
             │
             ▼
┌────────────────────────────────┐
│ authorize_quote_access!        │
│ • Get buyer from portal_access │
│ • Check buyer type:            │
│   - Lead: quote.account ==     │
│           buyer.converted_acct │
│   - Account: quote.account ==  │
│              buyer             │
└────────────┬───────────────────┘
             │
             ▼
┌────────────────────────────────┐
│ Authorized!                    │
│ • Proceed with request         │
│ • Return quote data            │
└────────────────────────────────┘


┌─────────────────────────────────────────────────────────────────────┐
│                      QUOTE STATUS TRANSITIONS                         │
└─────────────────────────────────────────────────────────────────────┘

    draft
      │
      │ (sent by company)
      ▼
    sent ─────────────┐
      │               │
      │ (buyer views) │ (buyer accepts)
      ▼               │
   viewed ────────────┼─────► accepted ✅
      │               │
      │               │ (buyer rejects)
      └───────────────┴─────► rejected ❌
      │
      │ (date passes valid_until)
      ▼
   expired ⏰


┌─────────────────────────────────────────────────────────────────────┐
│                      BUSINESS RULES                                   │
└─────────────────────────────────────────────────────────────────────┘

✅ CAN accept/reject if:
   • Status is 'sent' OR 'viewed'
   • Quote is NOT expired (valid_until >= today)
   • Buyer owns the quote

❌ CANNOT accept/reject if:
   • Status is 'draft' (not sent yet)
   • Status is 'accepted' (already accepted)
   • Status is 'rejected' (already rejected)
   • Status is 'expired' OR valid_until < today
   • Buyer doesn't own the quote
   • Quote is soft-deleted (is_deleted = true)


┌─────────────────────────────────────────────────────────────────────┐
│                      DATA FLOW EXAMPLE                                │
└─────────────────────────────────────────────────────────────────────┘

1. BUYER LISTS QUOTES
   ────────────────────
   GET /api/portal/quotes?status=sent&page=1&per_page=20
   
   → QuotesController#index
   → buyer_quotes (filtered by ownership)
   → .by_status('sent')
   → .order(created_at: :desc)
   → .limit(20).offset(0)
   → QuotePresenter.basic_json for each
   → Response with quotes + pagination


2. BUYER VIEWS QUOTE
   ──────────────────
   GET /api/portal/quotes/123
   
   → QuotesController#show
   → authorize_quote_access! (check ownership)
   → IF status == 'sent' AND viewed_at.nil?
      → Update to 'viewed', set viewed_at
   → QuotePresenter.detailed_json
   → Response with full quote details


3. BUYER ACCEPTS QUOTE
   ────────────────────
   POST /api/portal/quotes/123/accept
   Body: { "notes": "Looks good!" }
   
   → QuotesController#accept
   → authorize_quote_access! (check ownership)
   → Validate status (sent/viewed only)
   → Validate expiration
   → Update status to 'accepted', set accepted_at
   → Create Note with "Quote accepted: Looks good!"
   → Response with updated quote


┌─────────────────────────────────────────────────────────────────────┐
│                      TESTING ARCHITECTURE                             │
└─────────────────────────────────────────────────────────────────────┘

spec/
  ├── services/
  │   └── quote_presenter_spec.rb (11 tests)
  │       ├── basic_json format
  │       ├── detailed_json format
  │       ├── money formatting
  │       ├── item formatting
  │       └── nil handling
  │
  └── controllers/api/portal/
      └── quotes_controller_spec.rb (25+ tests)
          ├── Lead buyer scenarios
          │   ├── index (list, filter, paginate)
          │   ├── show (view, mark viewed)
          │   ├── accept (happy path, errors)
          │   └── reject (happy path, errors)
          │
          └── Account buyer scenarios
              ├── index
              └── show


┌─────────────────────────────────────────────────────────────────────┐
│                      KEY TECHNICAL DECISIONS                          │
└─────────────────────────────────────────────────────────────────────┘

1. SQLite Compatibility
   • NO jsonb (use text + serialize)
   • Compatible with development environment

2. Presenter Pattern
   • Separate JSON formatting from controller
   • Reusable across contexts
   • Easy to test independently

3. Polymorphic Buyers
   • Supports both Lead and Account buyers
   • Single authorization logic
   • Flexible for future buyer types

4. Soft Deletes
   • Quotes never truly deleted
   • Hidden from buyers via is_deleted flag
   • Audit trail preserved

5. Activity Tracking
   • Notes created on accept/reject
   • Includes buyer name and details
   • Full audit trail

6. Auto-Viewed Tracking
   • First view of 'sent' quote → 'viewed'
   • Subsequent views don't change timestamp
   • Provides engagement metrics


┌─────────────────────────────────────────────────────────────────────┐
│                      INTEGRATION POINTS                               │
└─────────────────────────────────────────────────────────────────────┘

Phase 4A (Authentication) ──► Phase 4B (Quotes)
  │                               │
  ├─ JWT tokens                   │
  ├─ BuyerPortalAccess model      │
  ├─ authenticate_portal_buyer!   │
  └─ current_portal_buyer         │
                                  │
                                  ▼
                            Future Phases
                            ├─ 4C: Documents
                            ├─ 4D: Preferences
                            └─ 4E: Profile


┌─────────────────────────────────────────────────────────────────────┐
│                      SECURITY LAYERS                                  │
└─────────────────────────────────────────────────────────────────────┘

Layer 1: Authentication
   ✓ JWT token required
   ✓ Token validation
   ✓ 401 if not authenticated

Layer 2: Authorization
   ✓ Buyer ownership check
   ✓ Quote-to-buyer relationship verified
   ✓ 403 if not authorized

Layer 3: Business Rules
   ✓ Status validation
   ✓ Expiration checking
   ✓ 422 if business rule violated

Layer 4: Data Protection
   ✓ Soft deletes hidden
   ✓ Sensitive data filtered
   ✓ Audit trail maintained
