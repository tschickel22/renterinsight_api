#!/bin/bash

echo "=================================="
echo "🚀 COMPANY USER INVITATION FIXES"
echo "=================================="
echo ""

# Check if we're in the right directory
if [ ! -f "Gemfile" ] || [ ! -d "app/services" ]; then
    echo "❌ Error: Not in Rails root directory!"
    echo "Please cd to ~/src/renterinsight_api first"
    exit 1
fi

echo "✅ In Rails root directory"
echo ""

# Run the test
echo "Running tests..."
echo ""

bundle exec rails runner test_company_user_fixes.rb

echo ""
echo "=================================="
echo "✅ Tests complete!"
echo "=================================="
echo ""
echo "📝 Next steps:"
echo ""
echo "1. Review the test results above"
echo "2. If all tests pass, commit and push changes:"
echo "   git add app/services/invitation_service.rb"
echo "   git add app/controllers/api/public/invitations_controller.rb"
echo "   git commit -m 'Fix: Add company_id to invited users and include phone in verification'"
echo "   git push origin main:staging"
echo ""
echo "3. On frontend, commit and push changes:"
echo "   git add src/pages/invitations/UniversalInvitationAcceptPage.tsx"
echo "   git commit -m 'Fix: Pre-populate phone number from invitation'"
echo "   git push origin feature/user-management:staging"
echo ""
echo "4. Test in staging:"
echo "   - Create new company user invitation"
echo "   - Verify phone is pre-populated"
echo "   - Verify user appears in list with 'invited' status"
echo ""
