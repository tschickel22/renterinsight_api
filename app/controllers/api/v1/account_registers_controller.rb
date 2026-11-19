# frozen_string_literal: true

# GET /api/v1/accounting/register?account_id=&start_date=&end_date=&location_id=
# One account's register (Accounting::RegisterService): opened from a bank
# card on Bank Transactions or from View register on the chart of accounts.
class Api::V1::AccountRegistersController < ApplicationController
  before_action :set_company_scope

  def show
    return unless authorize_action!('journal_entries', 'read')

    account = @company.chart_of_accounts.find_by(id: params[:account_id])
    return render(json: { error: 'Account not found' }, status: :not_found) unless account

    start_date = parse_date(params[:start_date]) || 90.days.ago.to_date
    end_date = parse_date(params[:end_date]) || Date.current
    return render(json: { error: 'The start date is after the end date' }, status: :bad_request) if start_date > end_date

    location_id = params[:location_id].presence && @company.locations.where(id: params[:location_id]).pick(:id)
    render json: Accounting::RegisterService.new(@company)
                   .call(account: account, start_date: start_date, end_date: end_date, location_id: location_id)
  end

  private

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
