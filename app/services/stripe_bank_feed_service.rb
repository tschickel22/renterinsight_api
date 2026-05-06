# frozen_string_literal: true

class StripeBankFeedService
  def initialize(company)
    @company = company
    configure_stripe!
  end

  def create_connection_session(bank_account)
    customer_id = ensure_stripe_customer(bank_account)

    session = Stripe::FinancialConnections::Session.create({
      account_holder: { type: 'customer', customer: customer_id },
      permissions: ['transactions', 'balances'],
      filters: { countries: ['US'] }
    })

    { client_secret: session.client_secret, session_id: session.id }
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeBankFeed] Session creation failed: #{e.message}")
    { error: e.message }
  end

  def complete_connection(bank_account, fc_account_id)
    fc_account = Stripe::FinancialConnections::Account.retrieve(fc_account_id)

    bank_account.update!(
      stripe_fc_account_id: fc_account_id,
      stripe_fc_status: 'active',
      stripe_fc_last_synced_at: nil,
      institution_name: fc_account.try(:institution_name) || bank_account.institution_name,
      account_mask: fc_account.try(:last4) || bank_account.account_mask
    )

    begin
      Stripe::FinancialConnections::Account.subscribe(
        fc_account_id,
        { features: ['transactions'] }
      )
    rescue Stripe::StripeError => e
      Rails.logger.warn("[StripeBankFeed] Subscribe failed (non-fatal): #{e.message}")
    end

    sync_transactions(bank_account)
  end

  def sync_transactions(bank_account)
    return { error: 'No FC account linked' } unless bank_account.stripe_fc_account_id.present?
    return { error: 'Account disconnected' } unless bank_account.stripe_fc_status == 'active'

    begin
      Stripe::FinancialConnections::Account.refresh(
        bank_account.stripe_fc_account_id,
        { features: ['transactions'] }
      )
    rescue Stripe::StripeError => e
      Rails.logger.warn("[StripeBankFeed] Refresh failed: #{e.message}")
    end

    since = bank_account.stripe_fc_last_synced_at || 90.days.ago
    imported = 0
    skipped = 0
    has_more = true
    starting_after = nil

    while has_more
      params = {
        account: bank_account.stripe_fc_account_id,
        transacted_at: { gte: since.to_i },
        limit: 100
      }
      params[:starting_after] = starting_after if starting_after

      begin
        txn_list = Stripe::FinancialConnections::Transaction.list(params)
      rescue Stripe::StripeError => e
        Rails.logger.error("[StripeBankFeed] Transaction list failed: #{e.message}")
        handle_stripe_error(bank_account, e)
        return { error: e.message, imported: imported, skipped: skipped }
      end

      txn_list.data.each do |txn|
        if bank_account.bank_transactions.exists?(stripe_txn_id: txn.id)
          skipped += 1
          next
        end

        bank_account.bank_transactions.create!(
          company: @company,
          transaction_date: Time.at(txn.transacted_at).to_date,
          post_date: txn.posted_at ? Time.at(txn.posted_at).to_date : nil,
          description: txn.description,
          amount: txn.amount / 100.0,
          reference_number: txn.id,
          fitid: txn.id,
          stripe_txn_id: txn.id,
          status: 'unmatched',
          transaction_type: txn.amount >= 0 ? 'credit' : 'debit'
        )
        imported += 1
      end

      has_more = txn_list.has_more
      starting_after = txn_list.data.last&.id
    end

    bank_account.update!(stripe_fc_last_synced_at: Time.current)

    if imported > 0
      matcher = BankTransactionMatchingService.new(@company)
      matcher.auto_match_all(bank_account)
    end

    { imported: imported, skipped: skipped }
  end

  def disconnect(bank_account)
    if bank_account.stripe_fc_account_id.present?
      begin
        Stripe::FinancialConnections::Account.unsubscribe(
          bank_account.stripe_fc_account_id,
          { features: ['transactions'] }
        )
      rescue Stripe::StripeError => e
        Rails.logger.warn("[StripeBankFeed] Unsubscribe failed (non-fatal): #{e.message}")
      end
    end

    bank_account.update!(
      stripe_fc_account_id: nil,
      stripe_fc_status: nil,
      stripe_fc_last_synced_at: nil
    )
  end

  private

  def configure_stripe!
    stripe_key = Setting.find_by(setting_type: 'platform', key: 'stripe_secret_key')&.value
    stripe_key ||= PlatformSetting.find_by(key: 'stripe_secret_key')&.value

    if stripe_key.present?
      Stripe.api_key = stripe_key
    else
      Rails.logger.error("[StripeBankFeed] No Stripe secret key configured!")
      raise "Stripe secret key not configured"
    end
  end

  def ensure_stripe_customer(bank_account)
    return bank_account.stripe_customer_id if bank_account.stripe_customer_id.present?

    company_stripe_id = Setting.find_by(
      setting_type: 'company',
      settable_id: @company.id,
      key: 'stripe_customer_id'
    )&.value

    if company_stripe_id.present?
      bank_account.update_column(:stripe_customer_id, company_stripe_id)
      return company_stripe_id
    end

    customer = Stripe::Customer.create({
      name: @company.name,
      email: @company.try(:email),
      metadata: {
        ri_company_id: @company.id,
        source: 'financial_connections'
      }
    })

    bank_account.update_column(:stripe_customer_id, customer.id)

    Setting.find_or_create_by(
      setting_type: 'company',
      settable_id: @company.id,
      settable_type: 'Company',
      key: 'stripe_customer_id'
    ).update!(value: customer.id)

    customer.id
  end

  def handle_stripe_error(bank_account, error)
    if error.message.include?('disconnected') || error.message.include?('inactive')
      bank_account.update!(stripe_fc_status: 'disconnected')
    end
  end
end
