# frozen_string_literal: true

class Api::V1::AccountingReportsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/accounting/reports/trial_balance
  def trial_balance
    return unless authorize_action!('financial_reports', 'read')

    as_of = params[:as_of_date] ? Date.parse(params[:as_of_date]) : Date.current
    location_id = params[:location_id]
    department = params[:department]

    service = Reports::TrialBalanceReportService.new(@company)
    report = service.generate(as_of_date: as_of, location_id: location_id, department: department)

    render json: report
  end

  # GET /api/v1/accounting/reports/general_ledger
  def general_ledger
    return unless authorize_action!('financial_reports', 'read')

    start_date = params[:start_date] ? Date.parse(params[:start_date]) : Date.current.beginning_of_month
    end_date = params[:end_date] ? Date.parse(params[:end_date]) : Date.current
    account_id = params[:account_id]

    unless account_id.present?
      return render json: { error: 'account_id is required' }, status: :bad_request
    end

    service = Reports::GeneralLedgerReportService.new(@company)
    report = service.generate(
      account_id: account_id,
      start_date: start_date,
      end_date: end_date,
      location_id: params[:location_id]
    )

    render json: report
  end
end
