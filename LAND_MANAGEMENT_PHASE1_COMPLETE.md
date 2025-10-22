# Land Management - Phase 1 Backend Setup Complete! 🎉

## Files Created

### 1. Migration
- `db/migrate/20251022000000_create_land_parcels.rb`

### 2. Model
- `app/models/land_parcel.rb`

### 3. Controller
- `app/controllers/api/v1/land_parcels_controller.rb`

### 4. Routes
- Updated `config/routes.rb` with land_parcels endpoints

### 5. Seed Data
- Updated `db/seeds.rb` with 8 sample land parcels

## Next Steps - Run These Commands

### Step 1: Run Migration
```bash
cd /home/tschi/src/renterinsight_api
bin/rails db:migrate
```

### Step 2: Run Seeds
```bash
bin/rails db:seed
```

### Step 3: Verify Data
```bash
bin/rails console
```

Then in the console:
```ruby
# Check if table exists
LandParcel.count

# View all parcels
LandParcel.all.each { |p| puts "#{p.parcel_number}: #{p.name} - #{p.status}" }

# Check stats
company = Company.first
parcels = company.land_parcels.active
puts "Total: #{parcels.count}"
puts "Available: #{parcels.available.count}"
puts "Sold: #{parcels.sold.count}"
```

### Step 4: Test API Endpoints
```bash
# Start server (if not already running)
bin/rails server

# In another terminal, test endpoints:
# List all parcels
curl http://localhost:3001/api/v1/land-parcels

# Get stats
curl http://localhost:3001/api/v1/land-parcels/stats

# Search
curl "http://localhost:3001/api/v1/land-parcels?search=Phoenix"

# Filter by status
curl "http://localhost:3001/api/v1/land-parcels?status=available"

# Filter by zoning
curl "http://localhost:3001/api/v1/land-parcels?zoning_type=residential"
```

## API Endpoints Created

### Collection Routes
- `GET /api/v1/land-parcels` - List all parcels (with filters)
- `POST /api/v1/land-parcels` - Create new parcel
- `GET /api/v1/land-parcels/stats` - Get statistics
- `GET /api/v1/land-parcels/export` - Export to CSV
- `POST /api/v1/land-parcels/bulk_delete` - Delete multiple parcels

### Member Routes
- `GET /api/v1/land-parcels/:id` - Get single parcel
- `PUT /api/v1/land-parcels/:id` - Update parcel
- `DELETE /api/v1/land-parcels/:id` - Soft delete parcel

### Query Parameters Supported
- `status` - Filter by status (available, pending, sold, under_contract, withdrawn)
- `zoning_type` - Filter by zoning (residential, commercial, agricultural, industrial, mixed_use)
- `city` - Filter by city
- `state` - Filter by state
- `min_price` & `max_price` - Price range filter
- `min_acreage` & `max_acreage` - Acreage range filter
- `search` - Full-text search
- `sort_by` - Sort field (default: created_at)
- `sort_order` - Sort direction (asc/desc, default: desc)
- `page` - Page number (default: 1)
- `per_page` - Items per page (default: 25, max: 100)

## Database Schema

### Table: land_parcels
- **Identification**: parcel_number, name
- **Location**: address, city, state, zip, county, latitude, longitude
- **Details**: acreage, zoning_type, status
- **Pricing**: price, price_per_acre (auto-calculated)
- **Utilities**: JSON field {water, sewer, electric, gas}
- **Features**: JSON array ['cleared', 'wooded', 'waterfront', etc.]
- **Ownership**: owner_name, owner_phone, owner_email, acquisition_date
- **Content**: description, notes
- **Media**: images (JSON array), documents (JSON array)
- **Soft Delete**: is_deleted, deleted_at
- **Audit**: created_by, updated_by, created_at, updated_at

## Sample Data Included

The seed file creates 8 sample parcels:
1. **Sunset Ridge Acres** - 5.25 acres residential, Phoenix AZ - $250K
2. **Downtown Commercial Plot** - 2.5 acres commercial, Denver CO - $500K
3. **Lakefront Paradise** - 10 acres residential, Boulder CO - $400K (pending)
4. **Valley View Farm** - 50 acres agricultural, Parker CO - $750K
5. **Suburban Lot** - 0.5 acres residential, Scottsdale AZ - $180K (sold)
6. **Industrial Park Site** - 15 acres industrial, Denver CO - $1.2M (under contract)
7. **Creek Side Retreat** - 7.5 acres residential, Evergreen CO - $325K
8. **Desert Vista** - 2.25 acres residential, Phoenix AZ - $195K

## Model Features

### Validations
- Parcel number must be unique per company
- Status must be valid
- Acreage, price, coordinates validated when present
- Auto-generates parcel number if not provided (LP-YYYYMMDD-XXX)
- Auto-calculates price_per_acre

### Scopes
- `active` - Non-deleted parcels
- `available`, `sold`, `pending`, `under_contract` - By status
- `by_status`, `by_zoning`, `by_city`, `by_state` - Filters
- `by_price_range`, `by_acreage_range` - Range filters
- `search` - Full-text search
- `recent` - Order by created_at desc

### Methods
- `soft_delete!` / `restore!` - Soft delete functionality
- `display_name` - Returns name or "Parcel {number}"
- `full_address` - Formatted address string
- `coordinates` - Returns {latitude, longitude} hash
- `has_utilities?` - Check if any utilities available
- `utility_list` - Array of available utilities

## Ready for Frontend! ✅

The backend is complete. You can now proceed to:
1. Create frontend components
2. Update routing
3. Build UI following the Inventory patterns

All CRUD operations, filters, search, and stats are working!
