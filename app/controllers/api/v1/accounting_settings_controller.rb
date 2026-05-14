# frozen_string_literal: true

class Api::V1::AccountingSettingsController < ApplicationController
  before_action :set_company_scope

  def show
    return unless authorize_action!('accounting', 'read')

    settings = AccountingSettings.for_company(@company)
    render json: settings.as_json(
      include: {
        retained_earnings_account: { only: [:id, :account_number, :name] },
        default_ar_account: { only: [:id, :account_number, :name] },
        default_ap_account: { only: [:id, :account_number, :name] },
        default_sales_revenue_account: { only: [:id, :account_number, :name] },
        default_cogs_account: { only: [:id, :account_number, :name] },
        default_sales_tax_payable_account: { only: [:id, :account_number, :name] },
        state_tax_account: { only: [:id, :account_number, :name] },
        county_tax_account: { only: [:id, :account_number, :name] },
        city_tax_account: { only: [:id, :account_number, :name] }
      }
    ).merge(allowed_form_states: @company.allowed_form_states || [])
  end

  def update
    return unless authorize_action!('accounting', 'update')

    settings = AccountingSettings.for_company(@company)

    if settings.update(settings_params)
      sync_allowed_form_states_from_tax_rates!(settings)
      render json: settings.as_json.merge(allowed_form_states: @company.allowed_form_states || [])
    else
      render json: { errors: settings.errors }, status: :unprocessable_entity
    end
  end

  def tax_rates_for_state
    return unless authorize_action!('accounting', 'read')

    state = params[:state].to_s.strip.upcase
    if state.blank?
      render json: { error: 'state parameter is required' }, status: :unprocessable_entity
      return
    end

    settings = AccountingSettings.for_company(@company)
    breakdown = settings.combined_tax_rate(state)

    render json: {
      state_code: state,
      rates: breakdown,
      source: (settings.tax_rates_by_state || {}).key?(state) ? 'state_override' : 'defaults'
    }
  end

  private

  def sync_allowed_form_states_from_tax_rates!(settings)
    return unless settings.tax_rates_by_state.present?

    tax_states = settings.tax_rates_by_state.keys.select { |k| k.to_s.match?(/\A[A-Z]{2}\z/) }
    return if tax_states.empty?

    current_form_states = @company.allowed_form_states || []
    new_states = (current_form_states + tax_states).uniq.sort
    return if new_states == current_form_states

    @company.update!(allowed_form_states: new_states)
  end

  def settings_params
    permitted = params.require(:accounting_settings).permit(
      :fiscal_year_start_month,
      :retained_earnings_account_id,
      :default_ar_account_id,
      :default_ap_account_id,
      :default_sales_revenue_account_id,
      :default_cogs_account_id,
      :default_sales_tax_payable_account_id,
      :default_bank_account_id,
      :auto_post_invoices,
      :auto_post_payments,
      :auto_post_purchases,
      :accounting_method,
      :lock_period_on_close,
      :check_number_sequence,
      :floor_plan_tracking_enabled,
      :default_floor_plan_rate,
      :default_floor_plan_lender,
      :sales_tax_enabled,
      :default_state_tax_rate,
      :default_county_tax_rate,
      :default_city_tax_rate,
      :state_tax_account_id,
      :county_tax_account_id,
      :city_tax_account_id
    )

    if params[:accounting_settings].key?(:tax_rates_by_state)
      raw = params[:accounting_settings][:tax_rates_by_state]
      permitted[:tax_rates_by_state] = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
    end

    permitted
  end
end
