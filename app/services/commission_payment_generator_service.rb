# frozen_string_literal: true

# CommissionPaymentGeneratorService
#
# Automatically generates commission payments when deals are delivered.
# Called from Deal model callback or background job.
#
# Usage:
#   service = CommissionPaymentGeneratorService.new(deal)
#   payment = service.generate
#   # => CommissionPayment record

class CommissionPaymentGeneratorService
  attr_reader :deal, :company, :user
  
  def initialize(deal, user = nil)
    @deal = deal
    @company = deal.company
    @user = user || deal.primary_salesperson
  end
  
  # Generate commission payment for this deal
  def generate
    unless @deal.delivered?
      Rails.logger.warn "[CommissionPaymentGenerator] Deal #{@deal.id} not delivered yet"
      return nil
    end
    
    unless @user.present?
      Rails.logger.warn "[CommissionPaymentGenerator] No payee user for deal #{@deal.id}"
      return nil
    end
    
    # Check if payment already exists for this deal and user
    existing = @company.commission_payments
      .where(deal_id: @deal.id, payee_user_id: @user.id)
      .where(is_deleted: [false, nil])
      .first
    
    if existing.present?
      Rails.logger.info "[CommissionPaymentGenerator] Payment already exists for deal #{@deal.id}"
      return existing
    end
    
    # Calculate commission
    calculator = CommissionCalculationService.new(@deal, @user)
    result = calculator.calculate
    
    if result[:total_commission] <= 0
      Rails.logger.info "[CommissionPaymentGenerator] No commission owed for deal #{@deal.id}"
      return nil
    end
    
    # Create the payment record
    payment = @company.commission_payments.create!(
      deal: @deal,
      location_id: @deal.location_id,
      payee_user: @user,
      amount: result[:total_commission],
      status: 'pending',
      calculation_details: {
        line_items: result[:line_items],
        deal_economics: result[:deal_economics],
        calculated_at: Time.current.iso8601
      },
      notes: "Auto-generated for #{@deal.name}"
    )
    
    Rails.logger.info "[CommissionPaymentGenerator] Created payment #{payment.payment_number} for $#{payment.amount}"
    
    payment
  rescue StandardError => e
    Rails.logger.error "[CommissionPaymentGenerator] Error generating payment: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    nil
  end
  
  # Class method for convenient access
  def self.generate_for_deal(deal, user = nil)
    new(deal, user).generate
  end
  
  # Regenerate payment (delete existing and create new)
  def regenerate
    # Find and soft-delete existing payments
    @company.commission_payments
      .where(deal_id: @deal.id, payee_user_id: @user.id)
      .where(status: 'pending')  # Only regenerate pending payments
      .update_all(is_deleted: true, deleted_at: Time.current)
    
    # Generate new payment
    generate
  end
  
  # Generate payments for multiple deals (bulk operation)
  def self.bulk_generate(deals)
    results = {
      created: 0,
      skipped: 0,
      errors: 0
    }
    
    deals.each do |deal|
      payment = generate_for_deal(deal)
      
      if payment.present?
        results[:created] += 1
      else
        results[:skipped] += 1
      end
    rescue StandardError => e
      Rails.logger.error "[CommissionPaymentGenerator] Bulk error for deal #{deal.id}: #{e.message}"
      results[:errors] += 1
    end
    
    results
  end
end
