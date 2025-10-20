-- SQL FIX for Quote #17 Opt-Out Error
-- Run these in your database (SQLite/PostgreSQL/MySQL)

-- STEP 1: Check what's wrong
-- Check for Quote-level preferences (THE PROBLEM)
SELECT * FROM communication_preferences WHERE recipient_type = 'Quote' AND recipient_id = 17;

-- Check Contact opt-out flags
SELECT c.id, c.email, c.first_name, c.last_name, c.opt_out_email, c.opt_out_sms
FROM contacts c
JOIN quotes q ON q.contact_id = c.id
WHERE q.id = 17;

-- STEP 2: Fix Quote-level preferences
-- Delete Quote-level preferences for Quote #17
DELETE FROM communication_preferences WHERE recipient_type = 'Quote' AND recipient_id = 17;

-- Delete ALL Quote-level preferences (recommended)
DELETE FROM communication_preferences WHERE recipient_type = 'Quote';

-- STEP 3: Fix Contact opt-out flags
-- Update Contact's opt-out flags to false
UPDATE contacts 
SET opt_out_email = 0, opt_out_sms = 0, opt_out_email_at = NULL, opt_out_sms_at = NULL
WHERE id = (SELECT contact_id FROM quotes WHERE id = 17);

-- STEP 4: Verify the fix
-- Should return 0 rows
SELECT * FROM communication_preferences WHERE recipient_type = 'Quote';

-- Check Contact flags are now false
SELECT c.id, c.email, c.opt_out_email, c.opt_out_sms
FROM contacts c
JOIN quotes q ON q.contact_id = c.id
WHERE q.id = 17;

-- STEP 5: Check Contact-level preferences (should be opted IN or not exist)
SELECT cp.*
FROM communication_preferences cp
JOIN quotes q ON q.contact_id = cp.recipient_id
WHERE cp.recipient_type = 'Contact' AND q.id = 17;

-- Optional: If Contact preferences are opted OUT, fix them
UPDATE communication_preferences
SET opted_in = 1, opted_out_at = NULL, opted_out_reason = NULL
WHERE recipient_type = 'Contact' 
AND recipient_id = (SELECT contact_id FROM quotes WHERE id = 17)
AND opted_in = 0;
