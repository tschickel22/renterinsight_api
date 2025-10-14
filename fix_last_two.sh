#!/bin/bash
cd ~/src/renterinsight_api

echo "=== Final Phase 4E Fixes ==="
echo ""

# Fix 1: Auth rate limiting - the issue is the before_action increments BEFORE checking
# So on the 6th call, it increments to 6, then checks > 5, which is true
# The test does 6 calls, so the 6th should be blocked
echo "1. Fixing auth controller rate limit logic..."

cat > /tmp/auth_fix.rb << 'EOF'
# Fix the rate_limit_auth! method
content = File.read('app/controllers/api/portal/auth_controller.rb')

# Replace the rate limiting logic
content.gsub!(/def rate_limit_auth!.*?end\n    end/m, <<~METHOD.chomp)
def rate_limit_auth!
        cache_key = "auth_attempts:\#{request.remote_ip}"
        attempts = Rails.cache.read(cache_key) || 0
        
        # Block if we've already hit the limit
        if attempts >= 5
          render json: {
            ok: false,
            error: 'Too many attempts. Please try again in 15 minutes.'
          }, status: :too_many_requests
          return
        end
        
        # Increment after checking
        Rails.cache.write(cache_key, attempts + 1, expires_in: 15.minutes)
      end
    end
METHOD

File.write('app/controllers/api/portal/auth_controller.rb', content)
puts "✓ Auth controller fixed"
EOF

bundle exec ruby /tmp/auth_fix.rb

# Fix 2: Communications controller tests - missing authentication helper
echo ""
echo "2. Fixing communications controller test authentication..."

# The tests need to set the auth header properly
cat > /tmp/comms_fix.rb << 'EOF'
content = File.read('spec/controllers/api/portal/communications_controller_spec.rb')

# Find all tests and add authentication
# Replace the before block to include token in request headers
if content.include?('before do')
  content.gsub!(/before do\n\s+@token = JsonWebToken\.encode\(buyer_portal_access_id: portal_access\.id\)\n  end/, <<~BLOCK.chomp)
before do
    @token = JsonWebToken.encode(buyer_portal_access_id: portal_access.id)
    request.headers['Authorization'] = "Bearer \#{@token}"
  end
BLOCK
else
  # Add it after let blocks
  content.sub!(/let\(:thread2\).*?end\n/m) do |match|
    match + "\n  before do\n    @token = JsonWebToken.encode(buyer_portal_access_id: portal_access.id)\n    request.headers['Authorization'] = \"Bearer \#{@token}\"\n  end\n"
  end
end

File.write('spec/controllers/api/portal/communications_controller_spec.rb', content)
puts "✓ Communications controller tests fixed"
EOF

bundle exec ruby /tmp/comms_fix.rb

echo ""
echo "=== All fixes applied! ==="
echo ""
echo "Running quick test on fixed components..."
bundle exec rspec spec/controllers/api/portal/auth_controller_spec.rb:87 --format documentation
