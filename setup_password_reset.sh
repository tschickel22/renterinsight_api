#!/bin/bash

# Password Reset Setup and Test Script

echo "========================================="
echo "Password Reset Feature Setup"
echo "========================================="

# Navigate to the backend directory
cd "$(dirname "$0")"

echo ""
echo "Step 1: Running database migration..."
bundle exec rails db:migrate

if [ $? -ne 0 ]; then
  echo "❌ Migration failed!"
  exit 1
fi

echo "✅ Migration completed successfully"

echo ""
echo "Step 2: Testing password reset endpoints..."
echo ""

# Test 1: Request password reset with email for client
echo "Test 1: Request password reset (Client - Email)"
curl -X POST http://localhost:3000/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{
    "email": "sarah.johnson@example.com",
    "delivery_method": "email",
    "user_type": "client"
  }'

echo ""
echo ""

# Test 2: Request password reset with email for admin
echo "Test 2: Request password reset (Admin - Email)"
curl -X POST http://localhost:3000/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{
    "email": "admin@test.com",
    "delivery_method": "email",
    "user_type": "admin"
  }'

echo ""
echo ""

# Test 3: Request password reset with SMS
echo "Test 3: Request password reset (Client - SMS)"
curl -X POST http://localhost:3000/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{
    "phone": "+15551234567",
    "delivery_method": "sms",
    "user_type": "client"
  }'

echo ""
echo ""

# Test 4: Request password reset with auto-detect
echo "Test 4: Request password reset (Auto-detect)"
curl -X POST http://localhost:3000/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{
    "email": "admin@test.com",
    "delivery_method": "email",
    "user_type": "auto"
  }'

echo ""
echo ""

# Test 5: Verify an invalid token
echo "Test 5: Verify reset token (Invalid)"
curl -X POST http://localhost:3000/api/auth/verify_reset_token \
  -H "Content-Type: application/json" \
  -d '{
    "token": "invalid_token_12345"
  }'

echo ""
echo ""

# Test 6: Reset password with invalid token
echo "Test 6: Reset password (Invalid token)"
curl -X POST http://localhost:3000/api/auth/reset_password \
  -H "Content-Type: application/json" \
  -d '{
    "token": "invalid_token_12345",
    "password": "newpassword123"
  }'

echo ""
echo ""

echo "========================================="
echo "Setup Complete!"
echo "========================================="
echo ""
echo "✅ Password reset feature is now active"
echo ""
echo "Available Endpoints:"
echo "  POST /api/auth/request_password_reset"
echo "  POST /api/auth/verify_reset_token"
echo "  POST /api/auth/reset_password"
echo ""
echo "To test with a real token:"
echo "1. Trigger a password reset request"
echo "2. Check the Rails logs for the reset token/URL"
echo "3. Use that token to verify and reset password"
echo ""
