#!/bin/bash
cd ~/src/renterinsight_api

# Run migrations
echo "=== Running DB migrations ==="
bundle exec rails db:migrate RAILS_ENV=test

# Fix test file - replace symbol keys with string keys
echo ""
echo "=== Fixing test file ==="
sed -i "s/metadata\[:email_type\]/metadata['email_type']/g" spec/services/buyer_portal_service_spec.rb
sed -i "s/metadata\[:quote_number\]/metadata['quote_number']/g" spec/services/buyer_portal_service_spec.rb
sed -i "s/metadata\[:quote_total\]/metadata['quote_total']/g" spec/services/buyer_portal_service_spec.rb
sed -i "s/metadata\[:rejected_by\]/metadata['rejected_by']/g" spec/services/buyer_portal_service_spec.rb
sed -i "s/metadata\[:original_communication_id\]/metadata['original_communication_id']/g" spec/services/buyer_portal_service_spec.rb
sed -i "s/metadata\[:thread_id\]/metadata['thread_id']/g" spec/services/buyer_portal_service_spec.rb
sed -i "s/metadata\[:token_expires_at\]/metadata['token_expires_at']/g" spec/services/buyer_portal_service_spec.rb
sed -i "s/metadata: { email_type: 'welcome' }/metadata: { 'email_type' => 'welcome' }/g" spec/services/buyer_portal_service_spec.rb

echo "Done!"
echo ""
echo "=== Running BuyerPortalService tests ==="
bundle exec rspec spec/services/buyer_portal_service_spec.rb --format progress
