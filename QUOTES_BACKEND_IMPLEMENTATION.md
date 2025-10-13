# Quotes Module - Backend Implementation

## Overview
Complete backend implementation for the Quotes module, including database schema, models, controllers, and API endpoints.

## Files Created/Modified

### Database
- **Migration**: `db/migrate/20251012120000_create_quotes.rb`
  - Creates `quotes` table with all required fields
  - Includes indexes for performance
  - Supports soft delete

### Models
- **Quote Model**: `app/models/quote.rb`
  - Full CRUD operations
  - Status management (draft, sent, viewed, accepted, rejected, expired)
  - Automatic quote number generation
  - Automatic total calculation
  - Validations and scopes
  - JSON serialization for frontend compatibility

- **Updated Models**:
  - `app/models/account.rb` - Added `has_many :quotes`
  - `app/models/contact.rb` - Added `has_many :quotes`

### Controllers
- **Quotes Controller**: `app/controllers/api/v1/quotes_controller.rb`
  - Full REST API implementation
  - Filtering and pagination
  - Statistics endpoint
  - CSV export
  - Status transitions (send, accept, reject)

### Routes
- **Updated**: `config/routes.rb`
  - Added complete quotes resource routes under `/api/v1/quotes`

## Database Schema

```ruby
create_table "quotes" do |t|
  t.references :account, null: true, foreign_key: true
  t.references :contact, null: true, foreign_key: true
  t.string :customer_id
  t.string :vehicle_id
  t.string :quote_number, null: false
  t.string :status, null: false, default: 'draft'
  t.decimal :subtotal, precision: 15, scale: 2, default: 0.0
  t.decimal :tax, precision: 15, scale: 2, default: 0.0
  t.decimal :total, precision: 15, scale: 2, default: 0.0
  t.json :items, default: []
  t.date :valid_until
  t.datetime :sent_at
  t.datetime :viewed_at
  t.datetime :accepted_at
  t.datetime :rejected_at
  t.text :notes
  t.json :custom_fields, default: {}
  t.boolean :is_deleted, default: false
  t.datetime :deleted_at
  t.timestamps
end
```

## API Endpoints

### Base URL: `/api/v1/quotes`

#### 1. List Quotes
```
GET /api/v1/quotes
```

**Query Parameters:**
- `account_id` - Filter by account
- `contact_id` - Filter by contact
- `customer_id` - Filter by customer
- `status` - Filter by status (draft, sent, viewed, accepted, rejected, expired)
- `search` - Search in quote number or notes
- `sort_by` - Sort field (created_at, updated_at, total, valid_until)
- `sort_order` - Sort direction (asc, desc)
- `page` - Page number (default: 1)
- `per_page` - Items per page (default: 25)

**Response:**
```json
{
  "quotes": [
    {
      "id": "1",
      "accountId": "11",
      "contactId": null,
      "customerId": null,
      "vehicleId": null,
      "quote_number": "QUO-2025-A1B2C3D4",
      "status": "draft",
      "subtotal": 250.00,
      "tax": 25.00,
      "total": 275.00,
      "items": [
        {
          "id": "1",
          "description": "Product A",
          "quantity": 2,
          "unitPrice": 100.00,
          "total": 200.00
        }
      ],
      "validUntil": "2025-11-12",
      "notes": "Test quote",
      "custom_fields": {},
      "createdAt": "2025-10-12T12:00:00Z",
      "updatedAt": "2025-10-12T12:00:00Z",
      "account": {
        "id": "11",
        "name": "Account Name",
        "email": "account@example.com",
        "phone": "123-456-7890"
      }
    }
  ],
  "meta": {
    "current_page": 1,
    "total_pages": 1,
    "total_count": 1,
    "per_page": 25
  }
}
```

#### 2. Get Single Quote
```
GET /api/v1/quotes/:id
```

**Response:** Single quote object with account and contact details

#### 3. Create Quote
```
POST /api/v1/quotes
```

**Request Body:**
```json
{
  "quote": {
    "account_id": 11,
    "contact_id": 5,
    "status": "draft",
    "items": [
      {
        "id": "1",
        "description": "Product A",
        "quantity": 2,
        "unitPrice": 100.00,
        "total": 200.00
      }
    ],
    "tax": 25.00,
    "notes": "Sample quote",
    "valid_until": "2025-11-12",
    "custom_fields": {}
  }
}
```

**Notes:**
- `subtotal` and `total` are automatically calculated from items
- `quote_number` is automatically generated
- `valid_until` defaults to 30 days from now if not provided

#### 4. Update Quote
```
PATCH /api/v1/quotes/:id
```

**Request Body:** Same as create, but all fields are optional

#### 5. Delete Quote (Soft Delete)
```
DELETE /api/v1/quotes/:id
```

**Response:** 204 No Content

#### 6. Send Quote
```
POST /api/v1/quotes/:id/send
```

Changes status from 'draft' to 'sent' and sets `sent_at` timestamp.

#### 7. Accept Quote
```
POST /api/v1/quotes/:id/accept
```

Changes status to 'accepted' and sets `accepted_at` timestamp.

#### 8. Reject Quote
```
POST /api/v1/quotes/:id/reject
```

Changes status to 'rejected' and sets `rejected_at` timestamp.

#### 9. Get Statistics
```
GET /api/v1/quotes/stats
```

**Response:**
```json
{
  "total": 10,
  "by_status": {
    "draft": 3,
    "sent": 4,
    "accepted": 2,
    "rejected": 1
  },
  "total_value": 15000.00,
  "average_value": 1500.00,
  "recent_count": 5
}
```

#### 10. Export to CSV
```
GET /api/v1/quotes/export
```

Accepts same query parameters as list endpoint. Returns CSV file.

## Quote Statuses

1. **draft** - Initial state, quote is being created/edited
2. **sent** - Quote has been sent to customer
3. **viewed** - Customer has viewed the quote
4. **accepted** - Customer accepted the quote
5. **rejected** - Customer rejected the quote
6. **expired** - Quote has passed its valid_until date

## Status Transitions

```
draft → sent → viewed → accepted
                  ↓
                rejected
                  ↓
              (any) → expired (automatic when past valid_until date)
```

## Setup Instructions

### 1. Run Migration
```bash
cd /path/to/renterinsight_api
chmod +x run_quotes_migration.sh
./run_quotes_migration.sh
```

Or manually:
```bash
bundle exec rails db:migrate
```

### 2. Verify Routes
```bash
bundle exec rails routes | grep quotes
```

### 3. Test API
```bash
chmod +x test_quotes_api.sh
./test_quotes_api.sh
```

## Model Features

### Automatic Calculations
- Subtotal is automatically calculated from items
- Total = subtotal + tax

### Quote Number Generation
- Format: `QUO-YYYY-XXXXXXXX`
- Example: `QUO-2025-A1B2C3D4`
- Automatically generated and unique

### Validations
- Quote number must be unique
- Status must be valid
- Items must be an array
- Financial values must be >= 0
- Valid until date must be in future (for new quotes)

### Scopes
```ruby
Quote.active          # Non-deleted quotes
Quote.by_status('sent')
Quote.by_account(11)
Quote.by_contact(5)
Quote.valid           # Not expired
Quote.expired         # Past valid_until date
Quote.search('QUO-2025')
Quote.recent          # Ordered by created_at DESC
```

## Integration with Frontend

The backend is fully compatible with the existing frontend implementation:

- All IDs are returned as strings for consistency
- Date formats match frontend expectations
- JSON structure matches TypeScript interfaces
- Proper error messages for validation failures

## Testing

Use the included test script:
```bash
./test_quotes_api.sh
```

This will test:
1. ✅ List quotes (empty)
2. ✅ Create quote
3. ✅ Get specific quote
4. ✅ Update quote
5. ✅ Get statistics
6. ✅ Send quote (status transition)
7. ✅ List quotes (with data)

## Error Handling

All endpoints return appropriate HTTP status codes:
- `200 OK` - Successful GET/PATCH
- `201 Created` - Successful POST
- `204 No Content` - Successful DELETE
- `422 Unprocessable Entity` - Validation errors
- `404 Not Found` - Resource not found

Validation errors return:
```json
{
  "errors": ["Field is required", "Another error message"]
}
```

## Future Enhancements

Potential additions:
1. Quote templates
2. Email notifications when quote is sent/accepted/rejected
3. PDF generation
4. Quote versioning
5. Quote approval workflow
6. Integration with payment processing
7. Quote analytics and reporting

## Support

For issues or questions:
1. Check the test script output
2. Review Rails logs: `tail -f log/development.log`
3. Verify migration ran successfully: `bundle exec rails db:migrate:status`
