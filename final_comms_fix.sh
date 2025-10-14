#!/bin/bash
cd ~/src/renterinsight_api

echo "=== Final Communications Controller Fix ==="
echo ""
echo "Comparing with working controller spec..."

# Check how quotes controller does it
echo "Quotes controller auth:"
grep -A 3 "before do" spec/controllers/api/portal/quotes_controller_spec.rb | head -5

echo ""
echo "Communications controller auth:"
grep -A 3 "before do" spec/controllers/api/portal/communications_controller_spec.rb | head -5

echo ""
echo "Replacing communications spec with correct pattern..."

# Just copy the pattern from quotes controller
cat > /tmp/final_comms_fix.rb << 'RUBY'
content = File.read('spec/controllers/api/portal/communications_controller_spec.rb')

# Find where the spec type is declared and add proper setup right after the lets
# Look for the last let block
last_let_end = content.rindex(/let\([^)]+\).*?end\n/m)

if last_let_end
  # Find the end of that let block
  match_data = content.match(/let\([^)]+\).*?end\n/m, last_let_end)
  if match_data
    insert_pos = last_let_end + match_data[0].length
    
    # Remove any existing before blocks that try to set auth
    content.gsub!(/\n  before do\n.*?@request\.headers.*?\n  end\n/, '')
    
    # Insert the correct before block
    setup = <<~SETUP

  before do
    @token = JsonWebToken.encode(buyer_portal_access_id: portal_access.id)
    @request.headers['Authorization'] = "Bearer \#{@token}"
  end
    SETUP
    
    content.insert(insert_pos, setup)
  end
end

File.write('spec/controllers/api/portal/communications_controller_spec.rb', content)
puts "✓ Applied fix"
RUBY

bundle exec ruby /tmp/final_comms_fix.rb

echo ""
echo "Testing first failing spec only..."
bundle exec rspec spec/controllers/api/portal/communications_controller_spec.rb:116 --format documentation
