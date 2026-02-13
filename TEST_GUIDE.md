# Quick Test Guide - Public Inventory API

## Prerequisites

1. **PostgreSQL running:**
   ```bash
   docker start pg-local
   docker ps  # Should show pg-local
   ```

2. **Rails server running:**
   ```bash
   cd ~/src/renterinsight_api
   bin/rails server -b 'ssl://0.0.0.0:3001?cert=localhost+1.pem&key=localhost+1-key.pem'
   ```

3. **Database migrated:**
   ```bash
   bin/rails db:migrate
   ```

---

## Run Test Suite

**Single command:**
```bash
cd ~/src/renterinsight_api
chmod +x test_inventory_api.sh
./test_inventory_api.sh
```

**Expected output:**
```
╔════════════════════════════════════════════════════════════╗
║        Public Inventory API - Test Suite                  ║
╔════════════════════════════════════════════════════════════╝

Step 1: Database Setup
─────────────────────────────────────────────────────────────
✓ Company: Company.first
✓ Token: abc123...xyz789
✓ Public inventory: ENABLED

Step 2: Test Data Creation
─────────────────────────────────────────────────────────────
✓ Test vehicles created/verified

Step 3: API Endpoint Tests
─────────────────────────────────────────────────────────────

Test 1: GET /public/inventory (List Vehicles)
✓ PASS: List endpoint returned 2 vehicles (total: 2)

Test 2: GET /public/inventory/filters (Filter Options)
✓ PASS: Filters endpoint (2 makes, 2 years)

... (12 tests total)

╔════════════════════════════════════════════════════════════╗
║                    Test Summary                            ║
╚════════════════════════════════════════════════════════════╝

Total Tests:  12
Passed:       12
Failed:       0
Pass Rate:    100.0%

✓ All tests passed!
```

---

## What Tests Run

1. ✓ **List Vehicles** - GET /public/inventory
2. ✓ **Filter Options** - GET /public/inventory/filters
3. ✓ **Vehicle Detail** - GET /public/inventory/:id
4. ✓ **Filter by Make** - ?make=Forest+River
5. ✓ **Filter by Price** - ?min_price=0&max_price=50000
6. ✓ **Search** - ?search=Forest
7. ✓ **Pagination** - ?page=1&per_page=5
8. ✓ **Sorting** - ?sort_by=sale_price&sort_order=asc
9. ✓ **Branding Data** - meta.branding in response
10. ✓ **Invalid Token** - 401 Unauthorized
11. ✓ **Missing Token** - 401 Unauthorized
12. ✓ **Non-Existent Vehicle** - 404 Not Found

---

## Manual Testing (curl)

**Get your token:**
```bash
bin/rails runner "puts Company.first.public_inventory_token"
```

**Test endpoints:**
```bash
# List all vehicles
curl -k "https://localhost:3001/public/inventory?token=YOUR_TOKEN" | jq

# Get filters
curl -k "https://localhost:3001/public/inventory/filters?token=YOUR_TOKEN" | jq

# Get specific vehicle
curl -k "https://localhost:3001/public/inventory/1?token=YOUR_TOKEN" | jq

# Search
curl -k "https://localhost:3001/public/inventory?token=YOUR_TOKEN&search=Forest" | jq

# Filter by make
curl -k "https://localhost:3001/public/inventory?token=YOUR_TOKEN&make=Forest+River" | jq

# Paginate
curl -k "https://localhost:3001/public/inventory?token=YOUR_TOKEN&page=1&per_page=5" | jq
```

---

## Troubleshooting

### Error: "Connection refused"
**Fix:** Start Rails server
```bash
bin/rails server -b 'ssl://0.0.0.0:3001?cert=localhost+1.pem&key=localhost+1-key.pem'
```

### Error: "could not connect to server"
**Fix:** Start PostgreSQL
```bash
docker start pg-local
```

### Error: "PG::UndefinedColumn: ERROR: column companies.public_inventory_token"
**Fix:** Run migration
```bash
bin/rails db:migrate
```

### Error: "Invalid inventory token"
**Fix:** Check token is correct
```bash
bin/rails runner "
  company = Company.first
  puts 'Token: ' + company.public_inventory_token
  puts 'Enabled: ' + company.public_inventory_enabled.to_s
"
```

---

## Test Data Setup (Manual)

If you want to create specific test data:

```bash
bin/rails runner "
  company = Company.first
  location = company.locations.first
  
  # Create RV
  company.vehicles.create!(
    location: location,
    listing_type: 'rv',
    status: 'available',
    inventory_id: 'TEST-001',
    year: 2024,
    make: 'Test Make',
    model: 'Test Model',
    sale_price_cents: 5000000,
    condition: 'new'
  )
  
  puts 'Test vehicle created!'
"
```

---

## Next Steps After Tests Pass

1. **Phase 3:** Build embed code generator UI
2. **Phase 4:** Create public inventory widget (HTML page)
3. **Phase 5:** Integrate with website builder

---

## Quick Reference

**Base URL:** `https://localhost:3001/public/inventory`

**Required Param:** `?token=YOUR_TOKEN`

**Optional Params:**
- `make=Forest+River`
- `model=Cherokee`
- `year=2023`
- `min_price=25000&max_price=75000`
- `search=keyword`
- `page=1&per_page=10`
- `sort_by=sale_price&sort_order=desc`
- `location_id=1`
- `listing_type=rv` or `manufactured_home`
- `bedrooms=3` (manufactured homes)
- `bathrooms=2` (manufactured homes)

**Response Format:**
```json
{
  "items": [...vehicles...],
  "meta": {
    "total": 10,
    "page": 1,
    "per_page": 12,
    "total_pages": 1,
    "branding": {...},
    "settings": {...}
  }
}
```
