# frozen_string_literal: true

class Api::V1::StripeWebhooksController < ApplicationController
  skip_before_action :authenticate
  skip_before_action :set_company_scope, raise: false

  # POST /webhooks/stripe
  def receive
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    endpoint_secret = ENV['STRIPE_WEBHOOK_SECRET']

    if endpoint_secret.blank?
      Rails.logger.warn('[StripeWebhook] STRIPE_WEBHOOK_SECRET not configured — rejecting')
      return head :service_unavailable
    end

    begin
      event = Stripe::Webhook.construct_event(payload, sig_header, endpoint_secret)
    rescue JSON::ParserError, Stripe::SignatureVerificationError => e
      Rails.logger.warn("[StripeWebhook] Verification failed: #{e.message}")
      return head :bad_request
    end

    case event.type
    when 'financial_connections.account.refreshed_transactions'
      handle_transactions_refresh(event.data.object)
    when 'financial_connections.account.disconnected'
      handle_account_disconnected(event.data.object)
    else
      Rails.logger.info("[StripeWebhook] Unhandled event type: #{event.type}")
    end

    head :ok
  end

  private

  def handle_transactions_refresh(fc_account)
    bank_account = BankAccount.find_by(stripe_fc_account_id: fc_account.id)
    return unless bank_account

    SyncBankFeedJob.perform_later(bank_account.id)
  end

  def handle_account_disconnected(fc_account)
    bank_account = BankAccount.find_by(stripe_fc_account_id: fc_account.id)
    return unless bank_account

    bank_account.update!(
      stripe_fc_status: 'disconnected',
      stripe_error_message: 'Disconnected by institution or user'
    )
  end
end
