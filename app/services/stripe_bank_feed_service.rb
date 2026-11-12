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
      Stripe::FinancialConnections::Account.refresh_account(
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

  # How long a balance from the bank counts as today's.
  BALANCE_FRESH_FOR = 6.hours
  # Card lines can post a few weeks after the purchase, so the look back
  # starts this far before the date to catch every line posted after it.
  POSTING_LAG = 45.days
  # Banks hand over roughly this much history; past it the answer may miss lines.
  HISTORY_DAYS = 90

  # The bank's posted balance at the end of `date` (a day in `zone`), worked
  # back from today's posted balance minus every line posted after that day:
  #   balance on date = current balance - sum(posted lines dated after it, up to the balance's as_of)
  # Stripe signs balances the same way for banks and cards: positive is
  # money the account holder has, negative is money they owe. Pending and
  # voided lines are not in the posted balance, so they are left out.
  #
  # Stripe fetches balances in the background. A balance older than
  # BALANCE_FRESH_FOR (or older than the last transaction fetch) starts a
  # fresh fetch and answers pending; ask again a few seconds later.
  #
  # Returns one of
  #   { status: 'ready', balance: BigDecimal, as_of: Time, current: BigDecimal,
  #     posted_after: BigDecimal, lines_after: Integer, old_date: Boolean }
  #   { status: 'pending' }
  #   { status: 'unavailable', reason: String }
  def balance_on(bank_account, date, zone: Time.zone)
    return unavailable('Its bank feed is not connected') unless bank_account.stripe_fc_account_id.present? && bank_account.stripe_fc_status == 'active'

    fc = Stripe::FinancialConnections::Account.retrieve(bank_account.stripe_fc_account_id)
    return unavailable('The bank connection is no longer active. Reconnect it under Bank Transactions') unless fc.try(:status) == 'active'
    unless Array(fc.try(:permissions)).include?('balances')
      return unavailable('The bank was connected without balance access. Reconnect it to fill this in')
    end

    fc_card = fc.try(:category).to_s == 'credit'
    if fc_card != (bank_account.account_type == 'credit_card')
      return unavailable("Its bank feed is a #{fc_card ? 'credit card' : 'bank account'} at the bank, so it may be connected to the wrong account")
    end

    balance = fc.try(:balance)
    refreshes = [fc.try(:balance_refresh), fc.try(:transaction_refresh)].compact
    return { status: 'pending' } if refreshes.any? { |r| r.status == 'pending' }

    if needs_balance_refresh?(fc, balance)
      begin
        Stripe::FinancialConnections::Account.refresh_account(fc.id, { features: %w[balance transactions] })
        return { status: 'pending' }
      rescue Stripe::StripeError => e
        # Too soon to ask again, or the bank refused: use what Stripe has.
        Rails.logger.warn("[StripeBankFeed] Balance refresh failed for bank account #{bank_account.id}: #{e.message}")
        return unavailable('The bank did not send a balance. Try again later or type it from your statement') if balance.nil?
      end
    end
    if fc.try(:balance_refresh)&.status == 'failed' && balance.nil?
      return unavailable('The bank did not send a balance. Type it from your statement')
    end

    current_cents = balance.current.to_h.with_indifferent_access[:usd]
    return unavailable('The bank sent no balance in dollars') if current_cents.nil?

    as_of = Time.at(balance.as_of)
    after = posted_lines_after(fc.id, date, zone, as_of)
    after_cents = after.sum(&:amount)
    {
      status: 'ready',
      balance: BigDecimal(current_cents - after_cents) / 100,
      current: BigDecimal(current_cents) / 100,
      posted_after: BigDecimal(after_cents) / 100,
      lines_after: after.size,
      as_of: as_of,
      old_date: date < Time.current.in_time_zone(zone).to_date - HISTORY_DAYS
    }
  rescue Stripe::StripeError => e
    Rails.logger.warn("[StripeBankFeed] Balance unavailable for bank account #{bank_account.id}: #{e.message}")
    unavailable('Stripe did not answer. Try again in a minute')
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

  def unavailable(reason)
    { status: 'unavailable', reason: reason }
  end

  # Fetch again when there is no balance, it is stale, or the transactions
  # were last fetched before it (lines posted in between would be missing).
  def needs_balance_refresh?(fc, balance)
    return true if balance.nil?
    return true if Time.at(balance.as_of) < BALANCE_FRESH_FOR.ago

    # Both fetches started together stamp a second or so apart, hence the slack.
    txn_at = fc.try(:transaction_refresh)&.last_attempted_at
    txn_at.nil? || txn_at < balance.as_of - 300
  end

  # Posted lines that posted after the end of `date` and by `as_of`. The
  # posting date decides, as on a bank statement; a line without one uses
  # its transaction date.
  def posted_lines_after(fc_id, date, zone, as_of)
    lines = []
    starting_after = nil
    loop do
      params = { account: fc_id, transacted_at: { gte: (date - POSTING_LAG).in_time_zone(zone).beginning_of_day.to_i }, limit: 100 }
      params[:starting_after] = starting_after if starting_after
      page = Stripe::FinancialConnections::Transaction.list(params)
      page.data.each do |txn|
        next unless txn.status == 'posted'

        posted_ts = txn.try(:status_transitions)&.try(:posted_at) || txn.transacted_at
        next if posted_ts > as_of.to_i
        next unless Time.at(posted_ts).in_time_zone(zone).to_date > date

        lines << txn
      end
      break unless page.has_more && page.data.any?

      starting_after = page.data.last.id
    end
    lines
  end

  def handle_stripe_error(bank_account, error)
    if error.message.include?('disconnected') || error.message.include?('inactive')
      bank_account.update!(stripe_fc_status: 'disconnected')
    end
  end
end
