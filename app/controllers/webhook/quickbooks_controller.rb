# frozen_string_literal: true

class Webhook::QuickbooksController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false
  skip_before_action :authenticate
  
  def notifications
    verify_webhook_signature!
    
    payload = JSON.parse(request.body.read)
    
    payload['eventNotifications']&.each do |event|
      company = Company.find_by(quickbooks_realm_id: event['realmId'])
      next unless company
      
      event['dataChangeEvent']['entities']&.each do |entity|
        QuickbooksWebhook.create!(
          company: company,
          realm_id: event['realmId'],
          event_name: entity['name'],
          entity_name: entity['name'],
          entity_id: entity['id'],
          operation: entity['operation'],
          webhook_payload: event,
          status: 'pending'
        )
      end
    end
    
    render plain: 'OK', status: :ok
  rescue => e
    Rails.logger.error("QuickBooks webhook error: #{e.message}")
    render plain: 'Error', status: :unprocessable_entity
  end
  
  private
  
  def verify_webhook_signature!
    signature = request.headers['intuit-signature']
    return true if signature.blank? && !Rails.env.production?
    
    webhook_token = Rails.application.credentials.dig(:quickbooks, :webhook_verifier_token)
    payload = request.body.read
    request.body.rewind
    
    expected_signature = Base64.strict_encode64(
      OpenSSL::HMAC.digest('sha256', webhook_token, payload)
    )
    
    unless ActiveSupport::SecurityUtils.secure_compare(signature, expected_signature)
      raise 'Invalid webhook signature'
    end
  end
end
