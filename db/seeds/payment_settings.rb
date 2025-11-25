# frozen_string_literal: true

# Payment Settings Seed
#
# This file seeds the default platform-level payment processor settings.
# These settings can be overridden at the company level.
#
# Run with: rails db:seed or rails runner db/seeds/payment_settings.rb

puts "\n💳 Seeding Payment Settings..."

# Platform-Level Payment Processor Configuration
puts "Setting up platform payment processor defaults..."

# 1. Default Payment Processor (manual = no automated processing)
Setting.set('platform', nil, 'payment_processor', 'manual')

# 2. Fee Responsibility (who pays processing fees)
Setting.set('platform', nil, 'payment_fee_responsibility', 'customer')

# ========================================
# ZEGO CONFIGURATION
# ========================================
puts "Setting up Zego configuration..."

# Zego Credentials (initially blank - to be configured via UI)
Setting.set('platform', nil, 'zego_gateway_id', '')
Setting.set('platform', nil, 'zego_login', '')
Setting.set('platform', nil, 'zego_password', '')
Setting.set('platform', nil, 'zego_admin_api_key', '')
Setting.set('platform', nil, 'zego_admin_username', '')
Setting.set('platform', nil, 'zego_admin_password', '')
Setting.set('platform', nil, 'zego_payee_id', '')

# Zego API URLs
Setting.set('platform', nil, 'zego_api_url', 'https://api.zego.com/v1')
Setting.set('platform', nil, 'zego_admin_url', 'https://admin.zego.com/api')

# Zego Fee Structure (Pass-through rates)
# ACH - Fixed amount
Setting.set('platform', nil, 'zego_ach_fee_type', 'fixed')
Setting.set('platform', nil, 'zego_ach_fee_value', '1.00') # $1.00

# Debit Card - Percentage
Setting.set('platform', nil, 'zego_debit_fee_type', 'percentage')
Setting.set('platform', nil, 'zego_debit_fee_value', '3.0') # 3.0%

# Credit Card - Percentage
Setting.set('platform', nil, 'zego_credit_fee_type', 'percentage')
Setting.set('platform', nil, 'zego_credit_fee_value', '3.5') # 3.5%

# Cash Pay - Fixed amount
Setting.set('platform', nil, 'zego_cash_fee_type', 'fixed')
Setting.set('platform', nil, 'zego_cash_fee_value', '4.00') # $4.00

# ========================================
# STRIPE CONFIGURATION
# ========================================
puts "Setting up Stripe configuration..."

# Stripe Credentials (initially blank - to be configured via UI)
Setting.set('platform', nil, 'stripe_secret_key', '')
Setting.set('platform', nil, 'stripe_publishable_key', '')
Setting.set('platform', nil, 'stripe_webhook_secret', '')

# Stripe Fee Structure (Stripe's base + our markup)
Setting.set('platform', nil, 'stripe_base_percentage', '2.9') # Stripe's 2.9%
Setting.set('platform', nil, 'stripe_base_fixed', '0.30') # Stripe's $0.30
Setting.set('platform', nil, 'stripe_markup_percent', '0.6') # Our markup (0.6%)

# Combined effective rate for display: 3.5% + $0.30
Setting.set('platform', nil, 'stripe_effective_percentage', '3.5')

# ========================================
# LATE FEE CONFIGURATION
# ========================================
puts "Setting up late fee configuration..."

Setting.set('platform', nil, 'late_fee_enabled', 'true')
Setting.set('platform', nil, 'late_fee_grace_days', '5') # Grace period before assessing late fee
Setting.set('platform', nil, 'late_fee_type', 'fixed') # 'fixed' or 'percentage'
Setting.set('platform', nil, 'late_fee_amount', '25.00') # $25 flat late fee
Setting.set('platform', nil, 'late_fee_percentage', '5.0') # Or 5% of payment amount

# ========================================
# AUTOMATED PAYMENT CONFIGURATION
# ========================================
puts "Setting up automated payment configuration..."

Setting.set('platform', nil, 'auto_pay_enabled', 'true')
Setting.set('platform', nil, 'auto_pay_retry_attempts', '3') # Number of retry attempts
Setting.set('platform', nil, 'auto_pay_retry_days', '3') # Days between retries
Setting.set('platform', nil, 'auto_pay_notification_days', '3') # Days before payment to notify

# ========================================
# PAYMENT NOTIFICATION SETTINGS
# ========================================
puts "Setting up payment notification settings..."

Setting.set('platform', nil, 'payment_confirmation_enabled', 'true')
Setting.set('platform', nil, 'payment_reminder_enabled', 'true')
Setting.set('platform', nil, 'payment_reminder_days_before', '3') # Send reminder 3 days before due
Setting.set('platform', nil, 'payment_failed_notification_enabled', 'true')

puts "✅ Payment settings seeded successfully!"

# Display summary
puts "\n" + "="*80
puts "Payment Settings Summary"
puts "="*80
puts "\n📊 Default Configuration:"
puts "   Payment Processor: #{Setting.get('platform', nil, 'payment_processor')}"
puts "   Fee Responsibility: #{Setting.get('platform', nil, 'payment_fee_responsibility')}"
puts "\n💰 Zego Fees:"
puts "   ACH: $#{Setting.get('platform', nil, 'zego_ach_fee_value')} (fixed)"
puts "   Debit Card: #{Setting.get('platform', nil, 'zego_debit_fee_value')}% (percentage)"
puts "   Credit Card: #{Setting.get('platform', nil, 'zego_credit_fee_value')}% (percentage)"
puts "   Cash Pay: $#{Setting.get('platform', nil, 'zego_cash_fee_value')} (fixed)"
puts "\n💳 Stripe Fees:"
puts "   Base Rate: #{Setting.get('platform', nil, 'stripe_base_percentage')}% + $#{Setting.get('platform', nil, 'stripe_base_fixed')}"
puts "   Markup: #{Setting.get('platform', nil, 'stripe_markup_percent')}%"
puts "   Effective Rate: #{Setting.get('platform', nil, 'stripe_effective_percentage')}% + $#{Setting.get('platform', nil, 'stripe_base_fixed')}"
puts "\n⏰ Late Fees:"
puts "   Enabled: #{Setting.get('platform', nil, 'late_fee_enabled')}"
puts "   Grace Period: #{Setting.get('platform', nil, 'late_fee_grace_days')} days"
puts "   Amount: $#{Setting.get('platform', nil, 'late_fee_amount')}"
puts "\n🔄 Auto-Pay:"
puts "   Enabled: #{Setting.get('platform', nil, 'auto_pay_enabled')}"
puts "   Retry Attempts: #{Setting.get('platform', nil, 'auto_pay_retry_attempts')}"
puts "   Retry Interval: #{Setting.get('platform', nil, 'auto_pay_retry_days')} days"
puts "="*80

puts "\n✨ These settings can be:"
puts "   1. Configured via Platform Admin → Settings → Payments"
puts "   2. Overridden per-company if needed"
puts "   3. Retrieved using: Setting.get_with_fallback('key', company_id)"
