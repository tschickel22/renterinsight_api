# frozen_string_literal: true

# Connect a bank: one sign in through Stripe Financial Connections brings in
# every account the person picks there, each as a DealerTide bank account
# with its feed on (StripeBankFeedService#connect_session_accounts!). The
# per-account feed endpoints stay in BankAccountFeedsController.
class Api::V1::BankFeedsController < ApplicationController
  before_action :set_company_scope

  # POST /api/v1/bank_feeds/session
  def session_start
    return unless authorize_action!('bank_accounts_accounting', 'create')

    result = StripeBankFeedService.new(@company).create_company_session
    if result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      render json: result
    end
  end

  # POST /api/v1/bank_feeds/connect { session_id }
  def connect
    return unless authorize_action!('bank_accounts_accounting', 'create')
    return render(json: { error: 'session_id is required' }, status: :unprocessable_entity) if params[:session_id].blank?

    rows = StripeBankFeedService.new(@company).connect_session_accounts!(params[:session_id].to_s)
    render json: {
      accounts: rows.map do |r|
        ba = r[:bank_account]
        { status: r[:status], name: r[:name], reason: r[:reason], bank_account_id: ba&.id,
          account_type: ba&.account_type, institution_name: ba&.institution_name, account_mask: ba&.account_mask }
      end
    }
  rescue ArgumentError, Stripe::StripeError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
