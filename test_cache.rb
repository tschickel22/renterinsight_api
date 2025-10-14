#!/usr/bin/env ruby
# Test Rails cache in development

puts "Testing Rails.cache configuration..."
puts "Cache store: #{Rails.cache.class}"
puts ""

# Test write and read
Rails.cache.write("test_key", "test_value", expires_in: 1.minute)
value = Rails.cache.read("test_key")

if value == "test_value"
  puts "✅ Cache is working!"
  puts "   Wrote and read back: '#{value}'"
else
  puts "❌ Cache is NOT working!"
  puts "   Expected 'test_value', got: #{value.inspect}"
end

puts ""
puts "Testing rate limit cache..."
cache_key = "auth_attempts:test_ip"
Rails.cache.write(cache_key, 1, expires_in: 15.minutes)
attempts = Rails.cache.read(cache_key)
puts "   Wrote: 1, Read back: #{attempts.inspect}"

if attempts == 1
  puts "✅ Rate limit cache would work!"
else
  puts "❌ Rate limit cache would NOT work!"
end
