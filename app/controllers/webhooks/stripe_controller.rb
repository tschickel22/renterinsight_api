# frozen_string_literal: true

class Webhooks::StripeController < ApplicationController
  skip_before_action :authenticate
  skip_before_action :verify_authenticity_token, raise: false
  skip_before_action :set_company_scope, raise: false

  # POST /webhooks/stripe
  def receive
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']

    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, webhook_secret
      )
    rescue JSON::ParserError
      Rails.logger.error('[StripeWebhook] Invalid payload')
      head :bad_request
      return
    rescue Stripe::SignatureVerificationError
      Rails.logger.error('[StripeWebhook] Invalid signature')
      head :bad_request
      return
    end

    Rails.logger.info("[StripeWebhook] Received event: #{event.type} (#{event.id})")

    case event.type
    when 'financial_connections.account.refreshed_transactions'
      handle_transactions_refreshed(event)
    when 'financial_connections.account.deactivated'
      handle_account_deactivated(event)
    when 'financial_connections.account.disconnected'
      handle_account_disconnected(event)
    when 'financial_connections.account.reactivated'
      handle_account_reactivated(event)
    else
      Rails.logger.info("[StripeWebhook] Unhandled event type: #{event.type}")
    end

    head :ok
  end

  private

  def webhook_secret
    ENV['STRIPE_WEBHOOK_SECRET']
  end

  # ═══════════════════════════════════════════════════════
  # EVENT HANDLERS
  # ═══════════════════════════════════════════════════════

  # Stripe notifies us that new transactions are available
  # → sync the bank account immediately
  def handle_transactions_refreshed(event)
    fc_account_id = event.data.object.id
    bank_account = find_bank_account(fc_account_id)

    unless bank_account
      Rails.logger.warn("[StripeWebhook] No bank account found for FC account: #{fc_account_id}")
      return
    end

    Rails.logger.info("[StripeWebhook] Syncing transactions for #{bank_account.bank_name} (#{fc_account_id})")

    service = StripeBankFeedService.new(bank_account.company)
    result = service.sync_transactions(bank_account)

    Rails.logger.info("[StripeWebhook] Sync complete: imported=#{result[:imported]}, skipped=#{result[:skipped]}")
  rescue => e
    Rails.logger.error("[StripeWebhook] Transaction sync failed for #{fc_account_id}: #{e.message}")
  end

  # Account was deactivated by the institution
  def handle_account_deactivated(event)
    fc_account_id = event.data.object.id
    bank_account = find_bank_account(fc_account_id)
    return unless bank_account

    bank_account.update!(stripe_fc_status: 'inactive')
    Rails.logger.info("[StripeWebhook] Bank account #{bank_account.bank_name} marked inactive (deactivated by institution)")
  rescue => e
    Rails.logger.error("[StripeWebhook] Deactivation handler failed: #{e.message}")
  end

  # Account was disconnected by the user at the institution
  def handle_account_disconnected(event)
    fc_account_id = event.data.object.id
    bank_account = find_bank_account(fc_account_id)
    return unless bank_account

    bank_account.update!(stripe_fc_status: 'disconnected')
    Rails.logger.info("[StripeWebhook] Bank account #{bank_account.bank_name} marked disconnected")
  rescue => e
    Rails.logger.error("[StripeWebhook] Disconnect handler failed: #{e.message}")
  end

  # Account was reactivated after being inactive
  def handle_account_reactivated(event)
    fc_account_id = event.data.object.id
    bank_account = find_bank_account(fc_account_id)
    return unless bank_account

    bank_account.update!(stripe_fc_status: 'active')
    Rails.logger.info("[StripeWebhook] Bank account #{bank_account.bank_name} reactivated")

    # Auto-sync on reactivation
    service = StripeBankFeedService.new(bank_account.company)
    service.sync_transactions(bank_account)
  rescue => e
    Rails.logger.error("[StripeWebhook] Reactivation handler failed: #{e.message}")
  end

  # ═══════════════════════════════════════════════════════
  # HELPERS
  # ═══════════════════════════════════════════════════════

  def find_bank_account(fc_account_id)
    BankAccount.find_by(stripe_fc_account_id: fc_account_id)
  end
end
