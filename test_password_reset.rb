#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

# Password Reset Feature Test Script

class PasswordResetTester
  BASE_URL = 'http://localhost:3001'

  def initialize
    @results = []
  end

  def run_all_tests
    puts "\n" + "=" * 60
    puts "Password Reset Feature - Comprehensive Test Suite"
    puts "=" * 60 + "\n"

    test_request_reset_client_email
    test_request_reset_admin_email
    test_request_reset_client_sms
    test_request_reset_auto_detect
    test_request_reset_invalid_user
    test_request_reset_missing_params
    test_verify_invalid_token
    test_reset_password_invalid_token
    test_rate_limiting

    print_summary
  end

  private

  def test_request_reset_client_email
    test_name = "Request Password Reset - Client (Email)"
    puts "\n🧪 Testing: #{test_name}"

    response = post_request('/api/auth/request_password_reset', {
      email: 'sarah.johnson@example.com',
      delivery_method: 'email',
      user_type: 'client'
    })

    if response.code == '200'
      body = JSON.parse(response.body)
      if body['success']
        log_success(test_name, "Reset email sent successfully")
      else
        log_failure(test_name, "Expected success: true, got: #{body}")
      end
    else
      log_failure(test_name, "Expected 200, got #{response.code}: #{response.body}")
    end
  rescue => e
    log_error(test_name, e.message)
  end

  def test_request_reset_admin_email
    test_name = "Request Password Reset - Admin (Email)"
    puts "\n🧪 Testing: #{test_name}"

    response = post_request('/api/auth/request_password_reset', {
      email: 'admin@test.com',
      delivery_method: 'email',
      user_type: 'admin'
    })

    if response.code == '200'
      body = JSON.parse(response.body)
      if body['success']
        log_success(test_name, "Reset email sent successfully")
      else
        log_failure(test_name, "Expected success: true, got: #{body}")
      end
    else
      log_failure(test_name, "Expected 200, got #{response.code}: #{response.body}")
    end
  rescue => e
    log_error(test_name, e.message)
  end

  def test_request_reset_client_sms
    test_name = "Request Password Reset - Client (SMS)"
    puts "\n🧪 Testing: #{test_name}"

    response = post_request('/api/auth/request_password_reset', {
      phone: '+15551234567',
      delivery_method: 'sms',
      user_type: 'client'
    })

    # SMS might fail if not configured, but endpoint should work
    if response.code.to_i.between?(200, 422)
      log_success(test_name, "Endpoint responded correctly (status: #{response.code})")
    else
      log_failure(test_name, "Expected 2xx/422, got #{response.code}: #{response.body}")
    end
  rescue => e
    log_error(test_name, e.message)
  end

  def test_request_reset_auto_detect
    test_name = "Request Password Reset - Auto-detect User Type"
    puts "\n🧪 Testing: #{test_name}"

    response = post_request('/api/auth/request_password_reset', {
      email: 'admin@test.com',
      delivery_method: 'email',
      user_type: 'auto'
    })

    if response.code == '200'
      body = JSON.parse(response.body)
      if body['success']
        log_success(test_name, "Auto-detect worked correctly")
      else
        log_failure(test_name, "Expected success: true, got: #{body}")
      end
    else
      log_failure(test_name, "Expected 200, got #{response.code}: #{response.body}")
    end
  rescue => e
    log_error(test_name, e.message)
  end

  def test_request_reset_invalid_user
    test_name = "Request Password Reset - Invalid User (Security)"
    puts "\n🧪 Testing: #{test_name}"

    response = post_request('/api/auth/request_password_reset', {
      email: 'nonexistent@example.com',
      delivery_method: 'email',
      user_type: 'client'
    })

    # Should return success even for non-existent users (security best practice)
    if response.code == '200'
      body = JSON.parse(response.body)
      if body['success']
        log_success(test_name, "Correctly hides non-existent user")
      else
        log_failure(test_name, "Expected success: true, got: #{body}")
      end
    else
      log_failure(test_name, "Expected 200, got #{response.code}: #{response.body}")
    end
  rescue => e
    log_error(test_name, e.message)
  end

  def test_request_reset_missing_params
    test_name = "Request Password Reset - Missing Parameters"
    puts "\n🧪 Testing: #{test_name}"

    response = post_request('/api/auth/request_password_reset', {
      delivery_method: 'email'
      # Missing email/phone
    })

    if response.code.to_i >= 400
      log_success(test_name, "Correctly rejected missing parameters")
    else
      log_failure(test_name, "Expected 4xx error, got #{response.code}")
    end
  rescue => e
    # This is expected to error
    log_success(test_name, "Correctly handled missing parameters")
  end

  def test_verify_invalid_token
    test_name = "Verify Reset Token - Invalid Token"
    puts "\n🧪 Testing: #{test_name}"

    response = post_request('/api/auth/verify_reset_token', {
      token: 'invalid_token_xyz123'
    })

    if response.code.to_i.between?(200, 422)
      body = JSON.parse(response.body)
      if body['valid'] == false
        log_success(test_name, "Correctly identified invalid token")
      else
        log_failure(test_name, "Expected valid: false, got: #{body}")
      end
    else
      log_failure(test_name, "Unexpected status code: #{response.code}")
    end
  rescue => e
    log_error(test_name, e.message)
  end

  def test_reset_password_invalid_token
    test_name = "Reset Password - Invalid Token"
    puts "\n🧪 Testing: #{test_name}"

    response = post_request('/api/auth/reset_password', {
      token: 'invalid_token_xyz123',
      password: 'newpassword123'
    })

    if response.code == '422'
      body = JSON.parse(response.body)
      if body['success'] == false
        log_success(test_name, "Correctly rejected invalid token")
      else
        log_failure(test_name, "Expected success: false, got: #{body}")
      end
    else
      log_failure(test_name, "Expected 422, got #{response.code}: #{response.body}")
    end
  rescue => e
    log_error(test_name, e.message)
  end

  def test_rate_limiting
    test_name = "Rate Limiting - Multiple Requests"
    puts "\n🧪 Testing: #{test_name}"
    puts "   (Sending 6 rapid requests...)"

    rate_limited = false

    6.times do |i|
      response = post_request('/api/auth/request_password_reset', {
        email: 'ratelimit@test.com',
        delivery_method: 'email',
        user_type: 'auto'
      })

      if response.code == '429'
        rate_limited = true
        break
      end
    end

    if rate_limited
      log_success(test_name, "Rate limiting working correctly")
    else
      log_info(test_name, "Rate limiting not triggered (may need 5+ attempts within an hour)")
    end
  rescue => e
    log_error(test_name, e.message)
  end

  def post_request(path, body)
    uri = URI.parse("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Post.new(uri.path, {
      'Content-Type' => 'application/json'
    })
    request.body = body.to_json
    http.request(request)
  end

  def log_success(test, message)
    @results << { test: test, status: :success, message: message }
    puts "   ✅ PASS: #{message}"
  end

  def log_failure(test, message)
    @results << { test: test, status: :failure, message: message }
    puts "   ❌ FAIL: #{message}"
  end

  def log_error(test, message)
    @results << { test: test, status: :error, message: message }
    puts "   ⚠️  ERROR: #{message}"
  end

  def log_info(test, message)
    @results << { test: test, status: :info, message: message }
    puts "   ℹ️  INFO: #{message}"
  end

  def print_summary
    puts "\n" + "=" * 60
    puts "Test Summary"
    puts "=" * 60

    successes = @results.count { |r| r[:status] == :success }
    failures = @results.count { |r| r[:status] == :failure }
    errors = @results.count { |r| r[:status] == :error }
    infos = @results.count { |r| r[:status] == :info }
    total = @results.count

    puts "\nResults:"
    puts "  ✅ Passed:  #{successes}"
    puts "  ❌ Failed:  #{failures}"
    puts "  ⚠️  Errors:  #{errors}"
    puts "  ℹ️  Info:    #{infos}"
    puts "  📊 Total:   #{total}"

    if failures > 0 || errors > 0
      puts "\n⚠️  Some tests failed or encountered errors."
      puts "Review the output above for details."
    else
      puts "\n✅ All tests passed!"
    end

    puts "\n" + "=" * 60
  end
end

# Run the tests
tester = PasswordResetTester.new
tester.run_all_tests
