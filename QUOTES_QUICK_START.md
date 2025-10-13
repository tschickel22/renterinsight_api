# Quotes Module - Quick Start Guide

## 🚀 Quick Setup (Choose One)

### Option 1: Linux/Mac/WSL
```bash
cd /path/to/renterinsight_api
chmod +x setup_quotes.sh
./setup_quotes.sh
```

### Option 2: Windows
```cmd
cd C:\path\to\renterinsight_api
setup_quotes.bat
```

### Option 3: Manual
```bash
bundle exec rails db:migrate
bundle exec rails routes | grep quotes
```

## 📡 API Endpoints

Base URL: `http://localhost:3001/api/v1/quotes`

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/quotes` | List all quotes |
| GET | `/api/v1/quotes/:id` | Get specific quote |
| POST | `/api/v1/quotes` | Create new quote |
| PATCH | `/api/v1/quotes/:id` | Update quote |
| DELETE | `/api/v1/quotes/:id` | Delete quote |
| POST | `/api/v1/quotes/:id/send` | Send quote |
| POST | `/api/v1/quotes/:id/accept` | Accept quote |
| POST | `/api/v1/quotes/:id/reject` | Reject quote |
| GET | `/api/v1/quotes/stats` | Get statistics |
| GET | `/api/v1/quotes/export` | Export to CSV |

## 🧪 Quick Test

```bash
# List quotes
curl http://localhost:3001/api/v1/quotes

# Create a quote
curl -X POST http://localhost:3001/api/v1/quotes \
  -H "Content-Type: application/json" \
  -d '{
    "quote": {
      "account_id": 11,
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
      "notes": "Test quote"
    }
  }'
```

## 📊 Status Flow

```
draft → sent → viewed → accepted
                  ↓
                rejected
```

## ✅ What's Included

- ✅ Full REST API
- ✅ Database migration
- ✅ Quote model with validations
- ✅ Automatic quote number generation (QUO-2025-XXXXXXXX)
- ✅ Automatic total calculation
- ✅ Status transitions
- ✅ Soft delete
- ✅ Filtering & pagination
- ✅ Statistics endpoint
- ✅ CSV export
- ✅ Account & Contact associations

## 🔗 Frontend Integration

The backend is fully wired up and compatible with your existing frontend:
- Endpoints match your API service (`src/services/api/quotes.ts`)
- JSON structure matches TypeScript types
- All IDs returned as strings for consistency

## 📝 Key Files

```
Backend:
├── db/migrate/20251012120000_create_quotes.rb    # Migration
├── app/models/quote.rb                            # Model
├── app/controllers/api/v1/quotes_controller.rb    # Controller
└── config/routes.rb                               # Routes (updated)

Frontend (already exists):
├── src/services/api/quotes.ts                     # API service
├── src/modules/quote-builder/                     # Quote builder module
└── src/modules/accounts/components/AccountQuotesSection.tsx
```

## 🐛 Troubleshooting

### 404 Errors?
1. Make sure Rails server is running: `rails s -p 3001`
2. Verify migration ran: `bundle exec rails db:migrate:status`
3. Check routes: `bundle exec rails routes | grep quotes`

### Migration Issues?
```bash
# Check migration status
bundle exec rails db:migrate:status

# Rollback if needed
bundle exec rails db:rollback

# Re-run migration
bundle exec rails db:migrate
```

### Can't create quotes?
1. Check Rails logs: `tail -f log/development.log`
2. Verify account exists (account_id=11)
3. Check validation errors in response

## 📖 Full Documentation

See `QUOTES_BACKEND_IMPLEMENTATION.md` for complete documentation.

## 🎉 You're Ready!

Your Quotes module backend is fully wired up and ready to use!

Test it now:
```bash
./test_quotes_api.sh
```
