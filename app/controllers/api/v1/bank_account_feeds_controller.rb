# frozen_string_literal: true

class Api::V1::BankAccountFeedsController < ApplicationController
  before_action :set_company_scope
  before_action :set_bank_account

  # POST /api/v1/bank_accounts/:bank_account_id/feed/create_session
  def create_session
    return unless authorize_action!('bank_accounts_accounting', 'update')

    service = StripeBankFeedService.new(@company)
    result = service.create_connection_session(@bank_account)

    if result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      render json: result
    end
  end

  # POST /api/v1/bank_accounts/:bank_account_id/feed/complete_connection
  def complete_connection
    return unless authorize_action!('bank_accounts_accounting', 'update')

    service = StripeBankFeedService.new(@company)
    service.complete_connection(@bank_account, params[:fc_account_id])

    render json: {
      message: 'Bank feed connected',
      bank_account: @bank_account.reload.as_json(
        only: [:id, :bank_name, :stripe_fc_status, :stripe_fc_last_synced_at, :institution_name, :account_mask]
      )
    }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/bank_accounts/:bank_account_id/feed/sync
  def sync
    return unless authorize_action!('bank_accounts_accounting', 'update')

    service = StripeBankFeedService.new(@company)
    result = service.sync_transactions(@bank_account)

    render json: result
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/bank_accounts/:bank_account_id/feed/disconnect
  def disconnect
    return unless authorize_action!('bank_accounts_accounting', 'update')

    service = StripeBankFeedService.new(@company)
    service.disconnect(@bank_account)

    render json: { message: 'Bank feed disconnected' }
  end

  # GET /api/v1/bank_accounts/:bank_account_id/feed/status
  def status
    return unless authorize_action!('bank_accounts_accounting', 'read')

    render json: {
      connected: @bank_account.feed_connected?,
      status: @bank_account.stripe_fc_status,
      last_synced: @bank_account.stripe_fc_last_synced_at,
      institution: @bank_account.institution_name,
      account_mask: @bank_account.account_mask,
      unmatched_count: @bank_account.bank_transactions.unmatched.count
    }
  end

  # POST /api/v1/bank_accounts/:bank_account_id/feed/request_balance
  # Get bank balance: asks the bank (Stripe charges per successful fetch).
  def request_balance
    return unless authorize_action!('bank_accounts_accounting', 'update')

    render json: StripeBankFeedService.new(@company).request_balance!(@bank_account)
  end

  # GET /api/v1/bank_accounts/:bank_account_id/feed/balance
  # Whether the bank has answered, and the balance kept. Free to ask.
  def balance
    return unless authorize_action!('bank_accounts_accounting', 'read')

    result = StripeBankFeedService.new(@company).balance_status(@bank_account)
    @bank_account.reload
    render json: result.merge(bank_balance: @bank_account.bank_balance&.to_f,
                              bank_balance_as_of: @bank_account.bank_balance_as_of)
  end

  private

  def set_bank_account
    @bank_account = @company.bank_accounts.find(params[:bank_account_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Bank account not found' }, status: :not_found
  end
end
