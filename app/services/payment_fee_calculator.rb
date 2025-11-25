# frozen_string_literal: true

# Payment Fee Calculator Service
#
# Calculates processing fees for payments based on payment method type,
# processor configuration, and company settings. Supports both Zego
# (pass-through rates) and Stripe (base + markup) models, with both
# percentage-based and fixed-amount fees.
#
# Usage:
#   calc = PaymentFeeCalculator.calculate(100.00, 'ach', company)
#   # => {
#   #   base_fee: 1.00,
#   #   markup: 0,
#   #   total_fee: 1.00,
#   #   fee_type: 'fixed',
#   #   fee_value: 1.00,
#   #   rate_percent: 1.00,
#   #   total_charged: 101.00,
#   #   breakdown: {...}
#   # }

class PaymentFeeCalculator
  class << self
    # Main calculation method
    #
    # @param amount [Float] The payment amount
    # @param payment_method_type [String] Type: 'ach', 'debit_card', 'credit_card', 'cash'
    # @param company [Company, nil] Optional company for company-specific settings
    # @return [Hash] Fee calculation breakdown
    #
    def calculate(amount, payment_method_type, company = nil)
      return zero_fee_response(amount) if amount.to_f <= 0
      
      processor = Setting.get_with_fallback('payment_processor', company&.id, 'manual')
      
      case processor
      when 'zego'
        calculate_zego_fee(amount, payment_method_type, company)
      when 'stripe'
        calculate_stripe_fee(amount, payment_method_type, company)
      else
        zero_fee_response(amount)
      end
    end
    
    # Calculate if customer should pay the fee
    #
    # @param company [Company, nil] Optional company
    # @return [Boolean] True if customer pays fees
    #
    def customer_pays_fee?(company = nil)
      Setting.get_with_fallback('payment_fee_responsibility', company&.id, 'customer') == 'customer'
    end
    
    # Get fee configuration for a payment method type
    #
    # @param payment_method_type [String] Type: 'ach', 'debit_card', 'credit_card', 'cash'
    # @param company [Company, nil] Optional company
    # @return [Hash] Fee configuration
    #
    def fee_config(payment_method_type, company = nil)
      processor = Setting.get_with_fallback('payment_processor', company&.id, 'manual')
      
      case processor
      when 'zego'
        zego_fee_config(payment_method_type, company)
      when 'stripe'
        stripe_fee_config(company)
      else
        { fee_type: 'none', fee_value: 0 }
      end
    end
    
    private
    
    # Calculate Zego fees (pass-through model)
    # Zego supports both percentage and fixed fees per payment method
    #
    def calculate_zego_fee(amount, payment_method_type, company)
      # Normalize payment method type for settings lookup
      method_key = normalize_method_type(payment_method_type)
      
      # Get fee configuration from settings
      fee_type = Setting.get_with_fallback("zego_#{method_key}_fee_type", company&.id, 'fixed')
      fee_value = Setting.get_with_fallback("zego_#{method_key}_fee_value", company&.id, '0').to_f
      
      # Calculate fee based on type
      case fee_type
      when 'percentage'
        fee = amount * (fee_value / 100)
        rate_percent = fee_value
      when 'fixed'
        fee = fee_value
        rate_percent = amount > 0 ? ((fee / amount) * 100).round(2) : 0
      else
        fee = 0
        rate_percent = 0
      end
      
      {
        base_fee: fee.round(2),
        markup: 0, # Zego is pass-through, no markup
        total_fee: fee.round(2),
        fee_type: fee_type,
        fee_value: fee_value,
        rate_percent: rate_percent,
        total_charged: customer_pays_fee?(company) ? (amount + fee).round(2) : amount.round(2),
        breakdown: {
          original_amount: amount.round(2),
          processing_fee: fee.round(2),
          fee_description: fee_type == 'percentage' ? "#{fee_value}%" : "$#{fee_value}",
          responsibility: customer_pays_fee?(company) ? 'customer' : 'company',
          processor: 'zego',
          method_type: payment_method_type
        }
      }
    end
    
    # Calculate Stripe fees (base + markup model)
    # Stripe uses percentage + fixed fee structure: 2.9% + $0.30 + our markup
    #
    def calculate_stripe_fee(amount, payment_method_type, company)
      # Stripe's base fee structure
      base_percentage = Setting.get_with_fallback('stripe_base_percentage', company&.id, '2.9').to_f
      base_fixed = Setting.get_with_fallback('stripe_base_fixed', company&.id, '0.30').to_f
      
      # Calculate Stripe's base fee
      base_fee = (amount * (base_percentage / 100)) + base_fixed
      
      # Our markup on top of Stripe's fee
      markup_percent = Setting.get_with_fallback('stripe_markup_percent', company&.id, '0.6').to_f
      markup = amount * (markup_percent / 100)
      
      # Total fee
      total_fee = base_fee + markup
      total_percentage = amount > 0 ? ((total_fee / amount) * 100).round(2) : 0
      
      {
        base_fee: base_fee.round(2),
        markup: markup.round(2),
        total_fee: total_fee.round(2),
        fee_type: 'percentage_plus_fixed',
        fee_value: "#{(base_percentage + markup_percent).round(2)}% + $#{base_fixed}",
        rate_percent: total_percentage,
        total_charged: customer_pays_fee?(company) ? (amount + total_fee).round(2) : amount.round(2),
        breakdown: {
          original_amount: amount.round(2),
          stripe_base_percentage: base_percentage,
          stripe_base_fixed: base_fixed,
          stripe_base_fee: base_fee.round(2),
          company_markup_percentage: markup_percent,
          company_markup: markup.round(2),
          processing_fee: total_fee.round(2),
          fee_description: "#{base_percentage}% + $#{base_fixed} + #{markup_percent}% markup",
          effective_rate: "#{(base_percentage + markup_percent).round(2)}% + $#{base_fixed}",
          responsibility: customer_pays_fee?(company) ? 'customer' : 'company',
          processor: 'stripe',
          method_type: payment_method_type
        }
      }
    end
    
    # Zero fee response for manual payments
    #
    def zero_fee_response(amount)
      {
        base_fee: 0,
        markup: 0,
        total_fee: 0,
        fee_type: 'none',
        fee_value: 0,
        rate_percent: 0,
        total_charged: amount.to_f.round(2),
        breakdown: {
          original_amount: amount.to_f.round(2),
          processing_fee: 0,
          fee_description: 'No fee',
          responsibility: 'none',
          processor: 'manual',
          method_type: 'manual'
        }
      }
    end
    
    # Get Zego fee configuration for a payment method
    #
    def zego_fee_config(payment_method_type, company)
      method_key = normalize_method_type(payment_method_type)
      
      fee_type = Setting.get_with_fallback("zego_#{method_key}_fee_type", company&.id, 'fixed')
      fee_value = Setting.get_with_fallback("zego_#{method_key}_fee_value", company&.id, '0').to_f
      
      {
        fee_type: fee_type,
        fee_value: fee_value,
        description: fee_type == 'percentage' ? "#{fee_value}%" : "$#{fee_value}"
      }
    end
    
    # Get Stripe fee configuration
    #
    def stripe_fee_config(company)
      base_percentage = Setting.get_with_fallback('stripe_base_percentage', company&.id, '2.9').to_f
      base_fixed = Setting.get_with_fallback('stripe_base_fixed', company&.id, '0.30').to_f
      markup_percent = Setting.get_with_fallback('stripe_markup_percent', company&.id, '0.6').to_f
      
      {
        fee_type: 'percentage_plus_fixed',
        base_percentage: base_percentage,
        base_fixed: base_fixed,
        markup_percentage: markup_percent,
        effective_percentage: base_percentage + markup_percent,
        description: "#{(base_percentage + markup_percent).round(2)}% + $#{base_fixed}"
      }
    end
    
    # Normalize payment method type for settings keys
    # Converts 'debit_card' → 'debit', 'credit_card' → 'credit'
    #
    def normalize_method_type(payment_method_type)
      case payment_method_type.to_s.downcase
      when 'debit_card', 'debit'
        'debit'
      when 'credit_card', 'credit'
        'credit'
      when 'ach', 'bank', 'checking', 'savings'
        'ach'
      when 'cash'
        'cash'
      else
        payment_method_type.to_s.downcase
      end
    end
  end
end
