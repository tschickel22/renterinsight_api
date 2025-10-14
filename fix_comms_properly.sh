#!/bin/bash
cd ~/src/renterinsight_api

echo "=== Checking Communications Spec Setup ==="
head -100 spec/controllers/api/portal/communications_controller_spec.rb | tail -50

echo ""
echo "=== Fixing the spec properly ==="

cat > /tmp/fix_comms_properly.rb << 'RUBY'
content = File.read('spec/controllers/api/portal/communications_controller_spec.rb')

# Replace the incorrect before block
content.gsub!(/  before do\n    request\.headers\['Authorization'\] = "Bearer #\{valid_token\}"\n  end/, <<~BLOCK.chomp)
before do
    @token = JsonWebToken.encode(buyer_portal_access_id: portal_access.id)
    @request.headers['Authorization'] = "Bearer \#{@token}"
  end
BLOCK

File.write('spec/controllers/api/portal/communications_controller_spec.rb', content)
puts "✓ Fixed"
RUBY

bundle exec ruby /tmp/fix_comms_properly.rb

echo ""
echo "=== Testing again ==="
bundle exec rspec spec/controllers/api/portal/communications_controller_spec.rb:116 --format documentation
