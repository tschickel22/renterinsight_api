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

  # Connecting a bank, not one account: one sign in at the bank, and every
  # account the person ticks in Stripe's window (checking, savings, cards)
  # becomes a DealerTide bank account with its feed on. Used by Bank
  # Transactions and the QuickBooks switch's banks step.
  def create_company_session
    customer_id = ensure_stripe_customer(nil)

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

  # The accounts come from the session itself, read from Stripe with our key,
  # never from ids the browser sends. Each one connects to the DealerTide
  # bank account already holding it, else to an unconnected one added by hand
  # with the same last four and type, else to a new one. Returns a row per
  # account: { bank_account:, status: 'created' | 'connected' | 'reconnected' | 'skipped', reason: }.
  def connect_session_accounts!(session_id)
    session = Stripe::FinancialConnections::Session.retrieve(session_id)
    customer_id = session.try(:account_holder).try(:customer)
    raise ArgumentError, 'This bank connection belongs to another company' unless own_customer?(customer_id)

    Array(session.accounts&.data).map { |fc| connect_fc_account!(fc, customer_id) }
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
    rescue => e
      Rails.logger.warn("[StripeBankFeed] Refresh failed (non-fatal): #{e.message}")
    end

    since = bank_account.stripe_fc_last_synced_at || 90.days.ago
    # Lines before the feed start date are already in the opening balances
    # (set by the QuickBooks switch to the day after cutover).
    feed_start = bank_account.feed_start_date
    since = [since, feed_start.beginning_of_day].max if feed_start
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
      rescue => e
        Rails.logger.error("[StripeBankFeed] Transaction list failed: #{e.message}")
        handle_stripe_error(bank_account, e)
        return { error: e.message, imported: imported, skipped: skipped }
      end

      txn_list.data.each do |txn|
        if bank_account.bank_transactions.exists?(stripe_txn_id: txn.id)
          skipped += 1
          next
        end

        if feed_start && Time.at(txn.transacted_at).to_date < feed_start
          skipped += 1
          next
        end

        bank_account.bank_transactions.create!(
          company: @company,
          transaction_date: Time.at(txn.transacted_at).to_date,
          post_date: txn.status_transitions&.posted_at ? Time.at(txn.status_transitions.posted_at).to_date : nil,
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
    stripe_key = ENV['STRIPE_SECRET_KEY']
    stripe_key ||= Rails.application.credentials.dig(:stripe, :secret_key) rescue nil

    if stripe_key.present?
      Stripe.api_key = stripe_key
    else
      Rails.logger.error("[StripeBankFeed] No Stripe secret key configured! Set STRIPE_SECRET_KEY env var.")
      raise "Stripe secret key not configured"
    end
  end

  # A session's customer is this company's when one of its bank accounts
  # already uses it, or Stripe tags it with this company (set at creation).
  def own_customer?(customer_id)
    return false if customer_id.blank?
    return true if @company.bank_accounts.exists?(stripe_customer_id: customer_id)

    Stripe::Customer.retrieve(customer_id).try(:metadata).try(:[], 'ri_company_id').to_s == @company.id.to_s
  rescue Stripe::StripeError
    false
  end

  # bank_account is nil for a company-level connection (connect a bank),
  # which reuses the customer the company's bank accounts already have.
  def ensure_stripe_customer(bank_account)
    return bank_account.stripe_customer_id if bank_account&.stripe_customer_id.present?

    existing = @company.bank_accounts.where.not(stripe_customer_id: [nil, '']).pick(:stripe_customer_id)
    if existing
      bank_account&.update_column(:stripe_customer_id, existing)
      return existing
    end

    # Check if company already has a Stripe customer via AccountingSettings
    settings = AccountingSettings.for_company(@company) rescue nil
    if settings&.respond_to?(:stripe_customer_id) && settings.stripe_customer_id.present?
      bank_account&.update_column(:stripe_customer_id, settings.stripe_customer_id)
      return settings.stripe_customer_id
    end

    customer = Stripe::Customer.create({
      name: @company.name,
      email: @company.try(:email),
      metadata: {
        ri_company_id: @company.id,
        source: 'financial_connections'
      }
    })

    bank_account&.update_column(:stripe_customer_id, customer.id)

    # Save to AccountingSettings for reuse
    if settings
      settings.update(stripe_customer_id: customer.id) rescue nil
    end

    customer.id
  end

  def connect_fc_account!(fc, customer_id)
    type = fc_account_type(fc)
    return { bank_account: nil, status: 'skipped', name: fc_name(fc), reason: 'Only bank and credit card accounts have feeds here' } unless type

    institution = fc.try(:institution_name).presence
    last4 = fc.try(:last4).presence
    scope = @company.bank_accounts.where(is_deleted: [false, nil])

    bank = scope.find_by(stripe_fc_account_id: fc.id)
    status = bank ? 'reconnected' : nil
    unless bank
      bank = scope.where(stripe_fc_account_id: [nil, ''], account_type: type)
                  .where('account_mask = :l OR display_last_four = :l', l: last4).first if last4
      status = 'connected' if bank
    end
    unless bank
      bank = scope.create!(bank_name: fc_name(fc), account_type: type, account_purpose: BankAccount::ACCOUNT_PURPOSE_SYNC_ONLY,
                           stripe_customer_id: customer_id)
      status = 'created'
    end

    bank.update!(stripe_fc_account_id: fc.id, stripe_fc_status: 'active',
                 institution_name: institution || bank.institution_name, account_mask: last4 || bank.account_mask,
                 stripe_customer_id: bank.stripe_customer_id.presence || customer_id)
    begin
      Stripe::FinancialConnections::Account.subscribe(fc.id, { features: ['transactions'] })
    rescue Stripe::StripeError => e
      Rails.logger.warn("[StripeBankFeed] Subscribe failed (non-fatal): #{e.message}")
    end
    # The first pull is best effort: a failure here leaves the account
    # connected, and the next sync picks the lines up.
    begin
      sync_transactions(bank)
    rescue StandardError => e
      Rails.logger.warn("[StripeBankFeed] First sync failed for bank account #{bank.id}: #{e.message}")
    end
    { bank_account: bank.reload, status: status, name: bank.bank_name }
  end

  # cash/checking, cash/savings and credit/credit_card have feeds; anything
  # else (investments, loans) has no account type here.
  def fc_account_type(fc)
    case fc.try(:category).to_s
    when 'credit' then 'credit_card'
    when 'cash' then fc.try(:subcategory).to_s == 'savings' ? 'savings' : 'checking'
    end
  end

  def fc_name(fc)
    [fc.try(:institution_name).presence, fc.try(:display_name).presence].compact.uniq.join(' ').presence || 'Bank account'
  end

  def handle_stripe_error(bank_account, error)
    if error.message.include?('disconnected') || error.message.include?('inactive')
      bank_account.update!(stripe_fc_status: 'disconnected')
    end
  end
end
