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

  # GET /api/v1/accounting/reports/profit_and_loss
  def profit_and_loss
    return unless authorize_action!('financial_reports', 'read')

    start_date = params[:start_date] ? Date.parse(params[:start_date]) : Date.current.beginning_of_month
    end_date = params[:end_date] ? Date.parse(params[:end_date]) : Date.current

    service = Reports::ProfitAndLossReportService.new(@company)
    report = service.generate(
      start_date: start_date,
      end_date: end_date,
      location_id: params[:location_id],
      department: params[:department],
      compare_prior: params[:compare_prior] == 'true'
    )

    render json: report
  end

  # GET /api/v1/accounting/reports/balance_sheet
  def balance_sheet
    return unless authorize_action!('financial_reports', 'read')

    as_of = params[:as_of_date] ? Date.parse(params[:as_of_date]) : Date.current

    service = Reports::BalanceSheetReportService.new(@company)
    report = service.generate(as_of_date: as_of, location_id: params[:location_id])

    render json: report
  end

  # GET /api/v1/accounting/reports/ar_aging
  def ar_aging
    return unless authorize_action!('financial_reports', 'read')

    as_of = params[:as_of_date] ? Date.parse(params[:as_of_date]) : Date.current

    service = Reports::ArAgingReportService.new(@company)
    report = service.generate(as_of_date: as_of, location_id: params[:location_id])

    render json: report
  end

  # GET /api/v1/accounting/reports/ap_aging
  def ap_aging
    return unless authorize_action!('financial_reports', 'read')

    as_of = params[:as_of_date] ? Date.parse(params[:as_of_date]) : Date.current

    service = Reports::ApAgingReportService.new(@company)
    report = service.generate(as_of_date: as_of, location_id: params[:location_id])

    render json: report
  end

  # GET /api/v1/accounting/reports/source_entries
  def source_entries
    return unless authorize_action!('journal_entries', 'read')

    entity_type = params[:entity_type]
    entity_id = params[:entity_id]

    entries = @company.journal_entries
      .where(source_entity_type: entity_type, source_entity_id: entity_id)
      .includes(:journal_entry_lines)
      .order(entry_date: :desc)

    render json: {
      items: entries.as_json(
        include: {
          journal_entry_lines: {
            include: { chart_of_account: { only: [:id, :account_number, :name] } }
          }
        }
      ),
      total: entries.count
    }
  end
end
