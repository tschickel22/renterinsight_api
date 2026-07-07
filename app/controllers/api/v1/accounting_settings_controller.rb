# frozen_string_literal: true

class Api::V1::AccountingSettingsController < ApplicationController
  before_action :set_company_scope

  def show
    # Sales Reps hit this endpoint on every deal + account page open — the
    # FE reads tax rates and default terms out of it for deal calculation.
    # Gating on accounting:read locked out anyone without full accounting
    # access, which is what triggered the "permission denied" report even
    # though the user had full deals perms. Downgrade the read gate so
    # deals:create also satisfies it; update stays on accounting:update
    # (below) since only Finance/Admin should mutate GL account defaults.
    return unless authorize_settings_read!

    settings = AccountingSettings.for_company(@company)
    render json: settings_json(settings)
  end

  def update
    return unless authorize_action!('accounting', 'update')

    settings = AccountingSettings.for_company(@company)

    if settings.update(settings_params)
      sync_allowed_form_states_from_tax_rates!(settings)
      # Return the SAME shape as show (with account associations + effective tax accounts)
      # so the FE re-hydrates every GL-account display. Returning bare as_json here dropped
      # the nested *_account relations and blanked the account selections after any save.
      render json: settings_json(settings.reload)
    else
      render json: { errors: settings.errors }, status: :unprocessable_entity
    end
  end

  def tax_rates_for_state
    return unless authorize_settings_read!

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

  # Read gate for accounting settings. Either accounting:read (Finance /
  # Company Admin — historical semantic) OR deals:create (Sales Rep and
  # anyone else who writes deals — needs tax rates + default terms to
  # compute the deal). Renders 403 and returns false on failure so the
  # caller can `return unless`. Mirrors authorize_action!'s error shape.
  def authorize_settings_read!
    return true if can?('accounting', 'read') || can?('deals', 'create')
    Rails.logger.warn "[Authorization] DENIED for user #{current_user&.id}: accounting_settings:read (needs accounting:read OR deals:create)"
    render json: {
      error: 'Access denied',
      required_permission: 'accounting:read OR deals:create'
    }, status: :forbidden
    false
  end

  # Canonical settings serialization — used by BOTH show and update so the FE always
  # receives the nested GL-account associations and effective tax accounts. Keeping this
  # in one place prevents update from silently returning a thinner payload that blanks
  # the account selections in the UI.
  def settings_json(settings)
    settings.as_json(
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
    ).merge(
      allowed_form_states: @company.allowed_form_states || [],
      effective_tax_accounts: effective_tax_accounts_payload(settings)
    )
  end

  # Per-jurisdiction resolved tax account + whether it's the seeded default.
  def effective_tax_accounts_payload(settings)
    %i[state county city].each_with_object({}) do |jur, h|
      acct = settings.effective_tax_account(jur)
      h[jur] = {
        account: acct && { id: acct.id, account_number: acct.account_number, name: acct.name },
        is_default: settings.tax_account_is_default?(jur)
      }
    end
  end

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
