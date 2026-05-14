# frozen_string_literal: true

class Api::V1::AccountingYearEndCloseController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/accounting/year_end_close/preview?fiscal_year=2025
  def preview
    return unless authorize_action!('accounting', 'read')

    fiscal_year = params[:fiscal_year].to_i
    if fiscal_year < 2000 || fiscal_year > Date.today.year + 1
      return render json: { error: "Invalid fiscal year: #{fiscal_year}" }, status: :unprocessable_entity
    end

    service = Accounting::YearEndCloseService.new(@company)
    result = service.preview(fiscal_year)

    if result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      render json: result
    end
  end

  # POST /api/v1/accounting/year_end_close/execute
  def execute
    return unless authorize_action!('accounting', 'create')

    fiscal_year = params[:fiscal_year].to_i
    if fiscal_year < 2000 || fiscal_year > Date.today.year + 1
      return render json: { error: "Invalid fiscal year: #{fiscal_year}" }, status: :unprocessable_entity
    end

    service = Accounting::YearEndCloseService.new(@company)
    result = service.close_year!(fiscal_year, user: current_user)

    if result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      render json: result
    end
  end
end
