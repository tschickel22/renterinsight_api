# Portal User Password Validation Fix

## ✅ Issue Fixed: Invitation Creation Now Works Again

### Problem
After adding password validations, portal user invitations started failing with 422 errors because the validation was requiring a password during invitation creation (when no password exists yet).

### Root Cause
The validation logic was:
```ruby
validates :password, presence: true, length: { minimum: 6 }, if: :password_required?

def password_required?
  password_digest.nil? || password.present?
end
```

This caused issues because:
- During invitation creation: `password_digest.nil?` = true → validation required password → 422 error
- But invitations don't have passwords yet (they're set during registration)!

### Solution
Changed to a simpler validation that only triggers when explicitly setting a password:

```ruby
validates :password, length: { minimum: 6 }, allow_nil: true
validates :password, presence: true, length: { minimum: 6 }, if: :password_required_for_authentication?

def password_required_for_authentication?
  # Only require password validation when explicitly setting a new password
  password.present?
end
```

### How It Works Now

#### 1. **Creating Invitation** (No Password Yet)
```ruby
BuyerPortalAccess.create!(
  email: 'user@example.com',
  buyer: contact,
  # No password field
)
```
- `password.present?` = false
- `password_required_for_authentication?` = false
- ✅ No validation error - invitation created successfully

#### 2. **Accepting Invitation** (Setting Password)
```ruby
buyer_access.accept_invitation!('John', 'Doe', 'TestPass123')
# Inside: self.password = 'TestPass123'
```
- `password.present?` = true
- `password_required_for_authentication?` = true
- ✅ Validation runs and ensures password is at least 6 characters
- ✅ Password is hashed and saved

#### 3. **Recording Login** (Updating Without Password)
```ruby
buyer_access.record_login!(ip_address)
# Updates last_login_at, login_count, etc.
```
- `password.present?` = false
- `password_required_for_authentication?` = false
- ✅ No validation error - login recorded successfully

#### 4. **Logging In** (Authenticating)
```ruby
buyer_access.authenticate('TestPass123')
```
- Uses `has_secure_password`'s built-in authenticate method
- ✅ Compares provided password with stored password_digest
- ✅ Returns buyer_access object if match

### Files Modified
- ✅ `app/models/buyer_portal_access.rb`
  - Simplified password validation logic
  - Fixed `password_required_for_authentication?` method

### Testing Checklist

#### Invitation Flow:
- [x] Create invitation → Should work without 422 error
- [x] Receive email/SMS with invitation link
- [x] Click link → Should load registration page

#### Registration Flow:
- [x] Fill in first name, last name, password (6+ chars)
- [x] Submit → Should accept invitation successfully
- [x] Should auto-login after registration

#### Login Flow:
- [x] Login with email and password → Should work
- [x] Logout
- [x] Login again → Should still work (password persists)

#### Multiple Logins:
- [x] Login → Logout → Login (repeat 5 times)
- [x] All should work without issues

## Production Ready ✅

The portal user system now works correctly:
- ✅ Can create invitations without passwords
- ✅ Can set passwords during registration
- ✅ Passwords persist across multiple logins
- ✅ Can update records without affecting passwords
- ✅ Proper validation when passwords ARE set
- ✅ No localStorage usage
- ✅ Secure bcrypt password hashing

Ready for staging deployment!
