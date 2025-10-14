#!/bin/bash
cd ~/src/renterinsight_api

echo "=== Fixing Communications Controller Tests ==="

# The issue is that controller specs don't use request.headers the same way
# We need to use @request.headers in controller specs

cat > /tmp/fix_comms_auth.rb << 'RUBY'
content = File.read('spec/controllers/api/portal/communications_controller_spec.rb')

# Remove any existing before block that sets headers incorrectly
content.gsub!(/  before do\n    @token = JsonWebToken\.encode.*?\n.*?request\.headers.*?\n  end\n/, '')

# Find the describe block and add proper before block
# Look for the first "describe" or "context" after the lets
content.sub!(/(let\(:thread2\).*?end\n)([ \t]*describe|[ \t]*context)/m) do
  lets = $1
  describe_line = $2
  
  <<~BLOCK
#{lets}
  before do
    @token = JsonWebToken.encode(buyer_portal_access_id: portal_access.id)
    @request.headers['Authorization'] = "Bearer \#{@token}"
  end

#{describe_line}
  BLOCK
end

File.write('spec/controllers/api/portal/communications_controller_spec.rb', content)
puts "✓ Fixed communications controller test"
RUBY

bundle exec ruby /tmp/fix_comms_auth.rb

echo ""
echo "=== Testing communications controller again ==="
bundle exec rspec spec/controllers/api/portal/communications_controller_spec.rb --format progress
