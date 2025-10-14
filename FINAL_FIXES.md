# Phase 4E - Final Fixes Required

## Issue Summary

After initial fixes, we have 3 remaining categories of failures:

### 1. **Metadata Not Saving (10 failures in service spec)**
**Problem:** SQLite metadata stored as TEXT needs string keys, not symbol keys
**Files affected:** `app/services/buyer_portal_service.rb`

### 2. **Missing Account Variables (Multiple test files)**
**Problem:** Tests reference `account` but it's not defined in let blocks
**Files affected:** 
- `spec/integration/buyer_portal_flow_spec.rb`
- `spec/security/portal_authorization_spec.rb`

### 3. **CommunicationThread Missing Channel (Multiple failures)**
**Problem:** CommunicationThread requires `channel` field (required validation)
**Files affected:** All tests creating CommunicationThread

### 4. **Missing Routes (10 failures in auth controller)**
**Problem:** Routes for `verify_magic_link` and `request_reset` don't exist
**File:** `config/routes.rb`

---

## Fix 1: Metadata String Keys

**Change in:** `app/services/buyer_portal_service.rb`

Replace all metadata hashes to use **string keys instead of symbol keys**:

```ruby
# BEFORE (Wrong - symbols don't serialize to SQLite TEXT)
metadata: {
  email_type: 'welcome',
  buyer_access_id: buyer_access.id
}

# AFTER (Correct - strings serialize properly)
metadata: {
  'email_type' => 'welcome',
  'buyer_access_id' => buyer_access.id
}
```

Apply this to ALL 7 Communication.create! calls in the service.

---

## Fix 2: Add Account Variables to Tests

### Integration Spec
**File:** `spec/integration/buyer_portal_flow_spec.rb`

Add after the `lead` let block (around line 17):

```ruby
let(:account) do
  Account.create!(
    company: company,
    name: 'Jane Smith Account',
    email: 'jane@example.com',
    status: 'active'
  )
end

before do
  lead.update!(converted_account_id: account.id, is_converted: true)
end
```

### Security Spec  
**File:** `spec/security/portal_authorization_spec.rb`

Add after buyer1 and buyer2 let blocks:

```ruby
let(:account1) do
  Account.create!(
    company: company,
    name: 'Alice Account',
    email: 'alice@example.com',
    status: 'active'
  )
end

let(:account2) do
  Account.create!(
    company: company,
    name: 'Bob Account',
    email: 'bob@example.com',
    status: 'active'
  )
end

before do
  buyer1.update!(converted_account_id: account1.id, is_converted: true)
  buyer2.update!(converted_account_id: account2.id, is_converted: true)
end
```

---

## Fix 3: Add Channel to CommunicationThread

**All test files creating CommunicationThread** - Add `channel:` parameter:

```ruby
# BEFORE (Missing required field)
CommunicationThread.create!(
  participant_type: "Lead",
  participant_id: lead.id,
  subject: 'Welcome to our service'
)

# AFTER (With required channel)
CommunicationThread.create!(
  participant_type: "Lead",
  participant_id: lead.id,
  channel: 'portal_message',  # ← ADD THIS
  subject: 'Welcome to our service'
)
```

Channel options: `'email'`, `'sms'`, or `'portal_message'`

---

## Fix 4: Add Missing Routes

**File:** `config/routes.rb`

Find the portal auth routes section and add:

```ruby
namespace :api do
  namespace :portal do
    scope module: :portal do
      # Auth routes
      post 'auth/login', to: 'auth#login'
      post 'auth/request_magic_link', to: 'auth#request_magic_link'
      get 'auth/verify_magic_link', to: 'auth#verify_magic_link'  # ← ADD
      post 'auth/request_reset', to: 'auth#request_reset'          # ← ADD
      patch 'auth/reset_password', to: 'auth#reset_password'
      get 'auth/profile', to: 'auth#profile'
      
      # ... other routes
    end
  end
end
```

---

## Quick Fix Script

I'll create a script that does most of this automatically...
