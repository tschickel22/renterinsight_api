#!/bin/bash
# Quick script to update invitation templates on staging
cd "$(dirname "$0")"

echo "=================================="
echo "Updating Invitation Templates"
echo "=================================="
echo ""

# Run the update script
bundle exec rails runner update_invitation_templates.rb

echo ""
echo "=================================="
echo "Update complete!"
echo ""
echo "Next steps:"
echo "1. Test by creating a new company user"
echo "2. Check the email/SMS that is sent"
echo "3. Verify the link goes to /invitations/accept"
echo "=================================="
