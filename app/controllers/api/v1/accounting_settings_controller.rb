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
        default_sales_tax_payable_account: { only: [:id, :account_number, :name] }
      }
    )
  end

  def update
    return unless authorize_action!('accounting', 'update')

    settings = AccountingSettings.for_company(@company)

    if settings.update(settings_params)
      render json: settings
    else
      render json: { errors: settings.errors }, status: :unprocessable_entity
    end
  end

  private

  def settings_params
    params.require(:accounting_settings).permit(
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
      :default_floor_plan_lender
    )
  end
end
