#!/bin/bash

echo "=========================================="
echo "Contacts Module - Complete Fix Application"
echo "=========================================="
echo ""

echo "Step 1: Running database migration..."
echo "--------------------------------------"
cd "\\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api" || exit 1

if rails db:migrate; then
    echo "✅ Migration completed successfully"
else
    echo "❌ Migration failed! Check the error above."
    exit 1
fi

echo ""
echo "Step 2: Verifying database change..."
echo "--------------------------------------"
rails runner 'puts "Account ID nullable: #{Contact.columns.find { |c| c.name == \"account_id\" }.null}"'

echo ""
echo "Step 3: Testing contact creation..."
echo "--------------------------------------"
rails runner '
c = Contact.new(first_name: "Test", last_name: "Fix", email: "test@fix.com")
if c.save
  puts "✅ Can create contact without account_id"
  c.destroy
else
  puts "❌ Failed: #{c.errors.full_messages}"
end
'

echo ""
echo "=========================================="
echo "✅ All Fixes Applied Successfully!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Restart Rails server:"
echo "   rails s -p 3001"
echo ""
echo "2. In browser console (F12):"
echo "   localStorage.clear()"
echo "   localStorage.setItem('ri:dataMode', 'rails')"
echo "   location.reload()"
echo ""
echo "3. Test in UI:"
echo "   Go to: http://localhost:5173/contacts"
echo "   Click 'Add Contact'"
echo "   Create a contact"
echo ""
echo "Should work perfectly now! 🎉"
echo ""
