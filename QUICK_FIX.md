# QUICK FIX GUIDE - Invitation URLs Going to Login

## What Was Wrong
Invitation emails were sending users to `/login` instead of `/invitations/accept?token=...`

The templates in the database were using old variables:
- `{{login_url}}` instead of `{{invitation_url}}` ← **THIS WAS THE MAIN ISSUE**
- `{{admin_name}}` instead of `{{invited_by}}`
- `{{user_name}}` instead of `{{first_name}}`

## What We Fixed

### 1. Backend (Rails)
- ✅ Updated `app/models/communication_template.rb` with new variable definitions
- ✅ Created script to update database templates: `update_invitation_templates.rb`

### 2. Frontend (React)
- ✅ Updated `src/types/invitation.ts` to show correct variables in the UI

## How to Apply the Fix

### On Staging Server:

```bash
# SSH into your staging server or open WSL terminal
cd /home/tschi/src/renterinsight_api

# Run the update script (this will update the database templates)
bash update_templates_now.sh
```

### Expected Output:
```
==================================
Updating Invitation Templates
==================================

🔄 Updating Company User Invitation Templates...
================================================================================
✅ Deleted 1 old email template(s)
✅ Deleted 1 old SMS template(s)

✅ Created new EMAIL template (ID: ...)
   - Uses {{ invitation_url }} instead of {{ login_url }}
   - Uses {{ first_name }}, {{ invited_by }} instead of {{ user_name }}, {{ admin_name }}

✅ Created new SMS template (ID: ...)
   - Uses {{ invitation_url }} instead of {{ login_url }}
   - Uses {{ first_name }}, {{ invited_by }} instead of {{ user_name }}, {{ admin_name }}

================================================================================
✨ Template update complete!
```

## Test It

1. **Send a test invitation:**
   - Go to Company Settings → Users
   - Click "Add User"
   - Enter test email address
   - Select "Email" delivery method
   - Click "Send Invitation"

2. **Check the email:**
   - Open the invitation email
   - Look for the "Set Up My Account" button
   - Verify the URL looks like: `https://staging.crm.landlordinsight.com/invitations/accept?token=abc123...`
   - ❌ NOT: `https://staging.crm.landlordinsight.com/login`

3. **Click the link:**
   - Should load the invitation acceptance page
   - Should show a form to set password
   - Should NOT redirect to login page

## Verify the Fix

### Check Templates in Database:
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails console

# Check email template
template = CommunicationTemplate.find_by(template_type: 'company_user_invitation', channel: 'email')
puts template.body.include?('invitation_url') ? '✅ CORRECT' : '❌ WRONG'

# Should print: ✅ CORRECT
```

### Check Frontend UI:
1. Go to Company Settings → Users → Invite Templates tab
2. Click "Create Template"
3. Look at "Available Variables" section
4. Should see: `invitation_url`, `invited_by`, `first_name`
5. Should NOT see: `login_url`, `admin_name`, `user_name`

## If It's Still Not Working

### Check these things:

1. **Did the script run successfully?**
   - Look for the ✅ success messages
   - No error messages

2. **Are you testing with a NEW invitation?**
   - Old pending invitations may still have old URLs
   - Create a brand new test invitation

3. **Is the frontend deployed?**
   - The frontend changes update the UI for creating templates
   - If you created custom templates before the fix, update them manually

4. **Check the actual email:**
   - View the raw HTML source of the email
   - Search for "invitation_url" in the source
   - If you see "login" instead, the template didn't update

## Need Help?

### View the full fix documentation:
```bash
cat /home/tschi/src/renterinsight_api/INVITATION_URL_FIX.md
```

### Check what templates exist:
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails console

CommunicationTemplate.where(template_type: 'company_user_invitation').each do |t|
  puts "#{t.id}: #{t.name} (#{t.channel})"
  puts "  - invitation_url: #{t.body.include?('invitation_url') ? '✅ YES' : '❌ NO'}"
  puts "  - login_url: #{t.body.include?('login_url') ? '⚠️ OLD' : '✅ NONE'}"
  puts ""
end
```

## Summary

✅ **Fixed**: Templates now use `{{invitation_url}}` instead of `{{login_url}}`  
✅ **Fixed**: Frontend UI shows correct variable names  
✅ **Fixed**: Backend model has all new variables  
✅ **Result**: Invitation links now go to `/invitations/accept?token=...`

Run the script, test with a new invitation, and you're done! 🎉
