#!/usr/bin/env ruby
# frozen_string_literal: true
# Verify Phase 4B implementation is complete

puts "🔍 Verifying Phase 4B Implementation..."
puts ""

errors = []
warnings = []

# Check 1: Controller exists
controller_path = File.join(__dir__, 'app', 'controllers', 'api', 'portal', 'quotes_controller.rb')
if File.exist?(controller_path)
  puts "✅ QuotesController exists"
else
  errors << "❌ QuotesController not found at #{controller_path}"
end

# Check 2: Presenter exists
presenter_path = File.join(__dir__, 'app', 'services', 'quote_presenter.rb')
if File.exist?(presenter_path)
  puts "✅ QuotePresenter exists"
else
  errors << "❌ QuotePresenter not found at #{presenter_path}"
end

# Check 3: Routes configured
routes_output = `bundle exec rails routes | grep "api/portal/quotes"`
if routes_output.include?('api/portal/quotes')
  puts "✅ Routes configured"
  quote_routes = routes_output.split("\n")
  expected_routes = ['index', 'show', 'accept', 'reject']
  expected_routes.each do |route|
    if routes_output.include?(route)
      puts "   ✓ #{route} route present"
    else
      warnings << "   ⚠ #{route} route might be missing"
    end
  end
else
  errors << "❌ Routes not configured properly"
end

# Check 4: Tests exist
controller_test_path = File.join(__dir__, 'spec', 'controllers', 'api', 'portal', 'quotes_controller_spec.rb')
if File.exist?(controller_test_path)
  puts "✅ Controller tests exist"
else
  errors << "❌ Controller tests not found"
end

presenter_test_path = File.join(__dir__, 'spec', 'services', 'quote_presenter_spec.rb')
if File.exist?(presenter_test_path)
  puts "✅ Presenter tests exist"
else
  errors << "❌ Presenter tests not found"
end

# Check 5: Quote model has required methods
begin
  quote = Quote.new
  required_methods = [:expired?, :accept!, :reject!]
  required_methods.each do |method|
    if quote.respond_to?(method)
      puts "✅ Quote##{method} exists"
    else
      errors << "❌ Quote##{method} missing"
    end
  end
rescue => e
  errors << "❌ Error checking Quote model: #{e.message}"
end

# Check 6: BuyerPortalAccess model exists
begin
  BuyerPortalAccess.first
  puts "✅ BuyerPortalAccess model accessible"
rescue => e
  errors << "❌ BuyerPortalAccess model issue: #{e.message}"
end

# Check 7: JsonWebToken helper exists
begin
  if defined?(JsonWebToken)
    puts "✅ JsonWebToken helper exists"
  else
    errors << "❌ JsonWebToken helper not defined"
  end
rescue => e
  errors << "❌ Error checking JsonWebToken: #{e.message}"
end

# Check 8: Cache enabled?
if Rails.cache.class.to_s.include?('MemoryStore')
  puts "✅ Cache is enabled (MemoryStore)"
elsif Rails.cache.class.to_s.include?('NullStore')
  warnings << "⚠ Cache is using NullStore (run 'bin/rails dev:cache' to enable)"
else
  puts "✅ Cache enabled: #{Rails.cache.class}"
end

puts ""
puts "="*60

if errors.empty?
  puts "✅ All checks passed!"
  if warnings.any?
    puts ""
    puts "Warnings:"
    warnings.each { |w| puts w }
  end
  puts ""
  puts "🚀 Phase 4B is ready!"
  puts ""
  puts "Next steps:"
  puts "1. Run tests: ./run_phase4b_tests.sh"
  puts "2. Create test data: bin/rails runner create_test_quotes.rb"
  puts "3. Start server: bin/rails s -p 3001"
  puts "4. Test with curl (see PHASE4B_SETUP.md)"
else
  puts "❌ Errors found:"
  errors.each { |e| puts e }
  
  if warnings.any?
    puts ""
    puts "Warnings:"
    warnings.each { |w| puts w }
  end
  
  puts ""
  puts "Please fix the errors above before proceeding."
  exit 1
end
