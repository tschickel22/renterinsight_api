#!/bin/bash
# Password Reset System - Verification Script

echo "🔍 Password Reset System - Verification"
echo "=========================================="
echo ""

cd ~/src/renterinsight_api

# Check if files exist
echo "📋 Checking Files..."
echo ""

files_to_check=(
  "PASSWORD_RESET_START_HERE.md"
  "PASSWORD_RESET_QUICK_REF.md"
  "PASSWORD_RESET_SETTINGS_INTEGRATION.md"
  "PASSWORD_RESET_FINAL_SUMMARY.md"
  "setup_password_reset_complete.sh"
  "create_test_users_password_reset.rb"
  "app/services/password_reset_service.rb"
  "app/services/sms_service.rb"
  "app/mailers/password_reset_mailer.rb"
  "app/models/password_reset_token.rb"
  "app/controllers/api/auth/password_reset_controller.rb"
  "db/migrate/20251015170000_create_password_reset_tokens.rb"
  "db/migrate/20251015180000_add_phone_to_users.rb"
)

all_found=true
for file in "${files_to_check[@]}"; do
  if [ -f "$file" ]; then
    echo "✅ $file"
  else
    echo "❌ MISSING: $file"
    all_found=false
  fi
done

echo ""
echo "=========================================="
echo ""

if [ "$all_found" = true ]; then
  echo "✅ All files present!"
  echo ""
  echo "🚀 Ready to run setup:"
  echo "   bash setup_password_reset_complete.sh"
  echo ""
  echo "📚 Documentation:"
  echo "   - START: PASSWORD_RESET_START_HERE.md"
  echo "   - QUICK: PASSWORD_RESET_QUICK_REF.md"
  echo "   - FULL:  PASSWORD_RESET_SETTINGS_INTEGRATION.md"
  echo ""
else
  echo "❌ Some files are missing!"
  echo "Please check the file paths."
fi
