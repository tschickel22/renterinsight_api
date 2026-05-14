# frozen_string_literal: true

class Api::V1::FiscalPeriodsController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('accounting', 'read')

    periods = @company.fiscal_periods.ordered
    periods = periods.for_year(params[:fiscal_year].to_i) if params[:fiscal_year].present?

    render json: { items: periods }
  end

  # POST /api/v1/fiscal_periods/generate
  def generate
    return unless authorize_action!('accounting', 'create')

    year = params[:fiscal_year]&.to_i || Date.current.year
    FiscalPeriod.generate_for_year(@company, year)

    render json: { message: "Generated fiscal periods for #{year}", items: @company.fiscal_periods.for_year(year).ordered }
  end

  # POST /api/v1/fiscal_periods/:id/close
  def close
    return unless authorize_action!('accounting', 'update')

    period = @company.fiscal_periods.find(params[:id])
    period.close!(current_user)

    render json: period
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/fiscal_periods/:id/reopen
  def reopen
    return unless authorize_action!('accounting', 'update')

    period = @company.fiscal_periods.find(params[:id])
    period.reopen!

    render json: period
  end
end
