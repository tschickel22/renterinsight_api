# Location Management Bug Fixes - Summary

## Issues Fixed

### 1. Communication Tab - Platform Settings Not Displaying
**Problem:** Location Communication tab showed "Platform Defaults" badge but displayed hardcoded values instead of actual platform settings from database.

**Root Cause:** `PlatformDefaults` module was using hardcoded values instead of reading from the Settings table via `PlatformSetting` model.

**Solution:** Updated `PlatformDefaults.communication_settings` to:
- Read from database via `PlatformSetting.communications`
- Handle both string keys (from JSON.parse) and symbol keys (from defaults)
- Normalize provider values to lowercase (smtp, twilio, etc.)
- Added debug logging to help troubleshoot

### 2. Activity Tab - Missing Settings Changes
**Problem:** Activity tab only showed user assignments and inventory, not branding/communication/operational settings changes.

**Root Cause:** 
- No activity tracking system for location settings changes
- `business_hours` column changes weren't being tracked (only `operational_settings` JSON column was tracked)

**Solution:** 
- Created `LocationActivity` model to track all location changes
- Added `after_update :track_settings_changes` callback to Location model
- Tracks changes to: `branding_settings`, `communication_settings`, `operational_settings`, `business_hours`, `timezone`, `delivery_radius_miles`
- Logs both setting updates and setting clears (when reverting to inherited)
- Updated controller to include LocationActivity records in activity feed

---

## Files Modified

### Backend Files

1. **app/services/concerns/platform_defaults.rb** (REWRITTEN)
   - Changed from hardcoded defaults to database-driven
   - Reads from `PlatformSetting.communications` and `PlatformSetting.branding`
   - Maps camelCase database keys to snake_case model keys
   - Normalizes provider values to lowercase
   - Added debug logging

2. **app/models/location_activity.rb** (NEW)
   - Tracks all location changes
   - Categories: branding, communication, operational, user_assignment, settings
   - Helper methods: `log_settings_change`, `log_settings_cleared`, `log_user_assignment`

3. **db/migrate/20251116012156_create_location_activities.rb** (NEW)
   - Creates `location_activities` table
   - Indexes on: category, action, occurred_at, location_id+occurred_at

4. **app/models/location.rb** (MODIFIED)
   - Added `has_many :location_activities` association
   - Added `after_update :track_settings_changes` callback
   - Tracks changes to all settings columns (JSON and regular columns)
   - Added `calculate_setting_changes` helper method

5. **app/controllers/api/v1/locations_controller.rb** (MODIFIED)
   - Enhanced `fetch_location_activities` to include LocationActivity records
   - Added `activity_type_from_category` helper
   - Added `activity_title_from_category` helper
   - Added activity logging to `assign_user` action

### Frontend Files

1. **src/pages/locations/tabs/ActivityTab.tsx** (MODIFIED)
   - Added Settings icon import
   - Added 'settings' case to ActivityIcon component

2. **src/services/locationsApi.ts** (MODIFIED)
   - Added 'settings' to LocationActivity type union
   - Added optional `user_name` field to LocationActivity

---

## Testing Instructions

### Step 1: Run Database Migration

```bash
# Via Docker
docker-compose exec api rails db:migrate

# OR directly
cd /home/tschi/src/renterinsight_api
rails db:migrate
```

### Step 2: Test Platform Defaults (Backend)

```bash
# Start Rails console
docker-compose exec api rails c

# Run test script
load 'test_platform_defaults.rb'
```

**Expected Output:**
- Platform settings should show actual database values (SMTP, renterinsight@gmail.com, etc.)
- NOT hardcoded values (sendgrid, noreply@renterinsight.com)

### Step 3: Test Locally (HTTPS)

1. **Start Backend:**
   ```bash
   cd /home/tschi/src/renterinsight_api
   docker-compose up
   ```

2. **Start Frontend:**
   ```bash
   cd C:\Users\tschi\src\Platform_DMS_8.4.25\Platform_DMS_8.4.25
   npm run dev
   ```

3. **Test Communication Tab:**
   - Navigate to: Locations → Select a location → Communication tab
   - **Before creating override:**
     - Badge should show "Platform Defaults"
     - Email Provider should show "smtp" (not "sendgrid")
     - From Email should show "renterinsight@gmail.com" (not "noreply@renterinsight.com")
     - From Name should show "RenterInsight Platform" (not "RenterInsight")
   - **Create override:** Click "Create Override", change a setting, save
   - Badge should now show "Set at Location"
   - Settings should show your overridden values

4. **Test Activity Tab - Settings Changes:**
   - Navigate to: Locations → Select a location → Activity tab
   - Should be empty initially (or show existing vehicle/user activities)
   - Go to Branding tab → Change primary color → Save
   - Return to Activity tab → Should show "Branding updated: primary color"
   - Go to Communication tab → Create override → Save
   - Return to Activity tab → Should show "Communication updated: ..."
   - Go to Operational tab → Change business hours → Save
   - Return to Activity tab → Should show "Operational settings updated: business hours"

5. **Test Activity Tab - User Assignment:**
   - Navigate to: Locations → Select a location → Users tab
   - Assign a user to the location
   - Go to Activity tab → Should show "User assigned: [name] assigned as [role]"

### Step 4: Check Logs

If Communication tab still shows wrong values:
```bash
# View backend logs
docker-compose logs -f api

# Look for lines containing:
# "PlatformDefaults.communication_settings - DB Communications:"
# "PlatformDefaults.communication_settings - Email Settings:"
# "PlatformDefaults.communication_settings - Result:"
```

Compare the logged values with your Platform Admin settings.

### Step 5: Deploy to Staging

```bash
# Backend
cd /home/tschi/src/renterinsight_api
git add .
git commit -m "Fix platform defaults and add location activity tracking"
git push origin staging

# Frontend  
cd C:\Users\tschi\src\Platform_DMS_8.4.25\Platform_DMS_8.4.25
git add .
git commit -m "Add settings activity type to location activities"
git push origin staging
```

### Step 6: Verify on Staging

1. **Check Render logs** to ensure migration ran automatically
2. **Test Communication tab** - verify platform settings display correctly
3. **Make a settings change** - verify it appears in Activity tab
4. **Assign a user** - verify it appears in Activity tab

---

## Troubleshooting

### Communication Settings Still Show Wrong Values

**Check 1:** Verify platform settings in database
```ruby
# Rails console
PlatformSetting.communications
# Should return: {email: {provider: "SMTP", fromEmail: "renterinsight@gmail.com", ...}}
```

**Check 2:** Check logs for PlatformDefaults output
```bash
docker-compose logs -f api | grep "PlatformDefaults"
```

**Check 3:** Verify LocationSettingsResolver is being called
```ruby
# Rails console
location = Location.first
location.resolved_communication_settings
# Should show platform values merged with company/location overrides
```

### Activity Tab Not Showing Changes

**Check 1:** Verify migration ran
```bash
docker-compose exec api rails db:migrate:status
# Should show: up 20251116012156 Create location activities
```

**Check 2:** Check if activities are being created
```ruby
# Rails console
LocationActivity.all
# Should show activity records
```

**Check 3:** Make a test change
```ruby
# Rails console
location = Location.first
location.update(branding_settings: {primary_color: '#ff0000'})
LocationActivity.where(location_id: location.id).last
# Should show the branding_changed activity
```

---

## Database Schema

### location_activities table
```sql
CREATE TABLE location_activities (
  id BIGINT PRIMARY KEY,
  location_id BIGINT NOT NULL,
  user_id BIGINT,
  action VARCHAR NOT NULL,
  category VARCHAR NOT NULL,
  description TEXT,
  metadata JSONB DEFAULT '{}',
  occurred_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE INDEX index_location_activities_on_category;
CREATE INDEX index_location_activities_on_action;
CREATE INDEX index_location_activities_on_occurred_at;
CREATE INDEX index_location_activities_on_location_id_and_occurred_at;
```

---

## Next Steps

After verifying everything works:

1. **Remove debug logging** from `platform_defaults.rb` (the `Rails.logger.info` lines)
2. **Consider adding activity tracking** for:
   - Location creation
   - Location deletion/restoration
   - User role changes (not just assignments)
   - Integration settings changes
3. **Add filtering to Activity tab** (by type, date range, user)
4. **Add export functionality** to Activity tab (CSV download)

---

## Questions?

If you encounter any issues:
1. Check the logs (both frontend console and backend logs)
2. Verify the migration ran successfully
3. Test the PlatformDefaults in Rails console
4. Share error messages and I can help debug
