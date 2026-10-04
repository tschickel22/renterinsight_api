# frozen_string_literal: true

class Api::V1::AccountingImportsController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('accounting', 'read')

    imports = @company.accounting_imports.recent
    render json: { items: imports }
  end

  def show
    return unless authorize_action!('accounting', 'read')

    import = @company.accounting_imports.find(params[:id])
    render json: import
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # POST /api/v1/accounting_imports/preview
  def preview
    return unless authorize_action!('accounting', 'create')

    service = Accounting::ImportService.new(@company, current_user)
    result = service.preview(
      source_type: params[:source_type],
      config: build_config
    )

    render json: result
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/accounting_imports/run
  def run_import
    return unless authorize_action!('accounting', 'create')

    service = Accounting::ImportService.new(@company, current_user)
    result = service.run_import!(
      source_type: params[:source_type],
      config: build_config,
      cutover_date: params[:cutover_date].present? ? Date.parse(params[:cutover_date]) : nil,
      entities: params[:entities]
    )

    render json: result, status: :created
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/accounting_imports/parse_iif
  def parse_iif
    return unless authorize_action!('accounting', 'create')

    file_content = read_uploaded_text

    return render json: { error: 'No file provided' }, status: :bad_request if file_content.blank?

    adapter = Accounting::Adapters::QuickbooksDesktopAdapter.new(@company, { 'file_data' => file_content })

    render json: {
      accounts: adapter.fetch_accounts.first(20),
      contacts: adapter.fetch_contacts.first(20),
      vendors: adapter.fetch_vendors.first(20),
      totals: {
        accounts: adapter.count_accounts,
        contacts: adapter.count_contacts,
        vendors: adapter.count_vendors
      }
    }
  rescue => e
    render json: { error: "Failed to parse file: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /api/v1/accounting_imports/parse_csv
  def parse_csv
    return unless authorize_action!('accounting', 'create')

    require 'csv'

    file_content = read_uploaded_text
    return render json: { error: 'No file provided' }, status: :bad_request if file_content.blank?

    rows = CSV.parse(file_content, headers: false)
    headers = rows.first || []
    sample_rows = rows[1..5] || []

    render json: {
      headers: headers,
      sample_rows: sample_rows,
      total_rows: rows.count - 1,
      entity_type: params[:entity_type] || 'accounts'
    }
  rescue CSV::MalformedCSVError => e
    render json: { error: "Invalid CSV: #{e.message}" }, status: :unprocessable_entity
  end

  # ── Switching from QuickBooks Online ──────────────────────────
  # Contract: qbo_migration_contract.md. All state lives on the
  # AccountingImport (Accounting::QboMigration::Wizard).

  # POST /api/v1/accounting_imports/migrations { cutover_date }
  def create_migration
    return unless authorize_action!('accounting', 'create')

    date = parse_cutover(params[:cutover_date])
    return render(json: { error: 'Choose a cutover date' }, status: :unprocessable_entity) unless date

    import = Accounting::QboMigration::Wizard.start!(company: @company, user: current_user, cutover_date: date)
    render json: { migration: wizard_for(import).migration_json }, status: :created
  rescue Accounting::QboMigration::Error, QuickbooksApiError, QuickbooksAuthError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /api/v1/accounting_imports/:id/migration
  def migration
    return unless authorize_action!('accounting', 'read')
    return unless (wizard = load_wizard)

    render json: { migration: wizard.migration_json }
  end

  # PATCH /api/v1/accounting_imports/:id/migration { cutover_date }
  def update_migration
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    date = parse_cutover(params[:cutover_date])
    return render(json: { error: 'Choose a cutover date' }, status: :unprocessable_entity) unless date

    with_migration_errors { wizard.change_cutover!(date) } or return
    render json: { migration: wizard_for(wizard.import.reload).migration_json }
  end

  # GET /api/v1/accounting_imports/:id/accounts
  def accounts
    return unless authorize_action!('accounting', 'read')
    return unless (wizard = load_wizard)

    render json: accounts_payload(wizard)
  end

  # POST /api/v1/accounting_imports/:id/accounts/suggest
  def suggest_accounts
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    with_migration_errors { Accounting::QboMigration::AccountSuggester.new(wizard).run! } or return
    render json: accounts_payload(wizard)
  end

  # PATCH /api/v1/accounting_imports/:id/accounts
  def update_accounts
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    permitted = params.permit(:confirm_suggested, accounts: [:qbo_account_id, :action, :chart_of_account_id, :confirmed,
                                                             { new_account: %i[number name account_type sub_type parent_id] }])
    with_migration_errors do
      wizard.update_accounts!(Array(permitted[:accounts]).map(&:to_h),
                              confirm_suggested: ActiveModel::Type::Boolean.new.cast(permitted[:confirm_suggested]))
    end or return
    render json: accounts_payload(wizard).merge(migration: wizard.migration_json)
  end

  # GET /api/v1/accounting_imports/:id/banks
  def banks
    return unless authorize_action!('accounting', 'read')
    return unless (wizard = load_wizard)

    render json: wizard.banks_json
  end

  # PATCH /api/v1/accounting_imports/:id/banks { matches: [...] }
  def update_banks
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    permitted = params.permit(matches: %i[qbo_account_id bank_account_id closed])
    with_migration_errors { wizard.update_banks!(Array(permitted[:matches]).map(&:to_h)) } or return
    render json: wizard.banks_json.merge(migration: wizard.migration_json)
  end

  # GET /api/v1/accounting_imports/:id/uncleared
  def uncleared
    return unless authorize_action!('accounting', 'read')
    return unless (wizard = load_wizard)

    render json: wizard.uncleared_json
  end

  # PUT /api/v1/accounting_imports/:id/uncleared { banks: [...] }
  def update_uncleared
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    permitted = params.permit(banks: [:qbo_account_id, :statement_balance,
                                      { items: %i[id date kind payee reference amount] }])
    raw_banks = Array(params[:banks])
    banks = Array(permitted[:banks]).each_with_index.map do |bank, idx|
      bank = bank.to_h
      # An emptied list arrives as items: [], which permit drops.
      raw = raw_banks[idx]
      bank['items'] = [] if raw.respond_to?(:key?) && raw.key?(:items) && !bank.key?('items')
      bank
    end
    with_migration_errors { wizard.update_uncleared!(banks) } or return
    render json: wizard.uncleared_json
  end

  # GET /api/v1/accounting_imports/:id/preview
  def migration_preview
    return unless authorize_action!('accounting', 'read')
    return unless (wizard = load_wizard)

    render json: wizard.preview_json
  end

  # POST /api/v1/accounting_imports/:id/post
  def post_migration
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    results = Accounting::QboMigration::Poster.new(wizard, current_user).post!
    render json: { migration: wizard_for(wizard.import.reload).migration_json, results: results }
  rescue Accounting::QboMigration::Poster::BlockedError => e
    render json: { error: 'This switch cannot post yet', blockers: e.blockers }, status: :unprocessable_entity
  rescue Accounting::QboMigration::Error, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/accounting_imports/:id/rollback
  def rollback_migration
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    Accounting::QboMigration::Rollback.new(wizard).run!(current_user)
    render json: { migration: wizard_for(wizard.import.reload).migration_json }
  rescue Accounting::QboMigration::Error, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def load_wizard
    import = @company.accounting_imports.find_by(id: params[:id])
    unless import&.migration?
      render json: { error: 'Not found' }, status: :not_found
      return nil
    end
    wizard_for(import)
  end

  def wizard_for(import)
    Accounting::QboMigration::Wizard.new(import)
  end

  def accounts_payload(wizard)
    { accounts: wizard.accounts_json, dealertide_accounts: wizard.dealertide_accounts_json,
      note: wizard.config.dig('notes', 'suggest') }
  end

  # Runs the block; on a migration error renders 422 and returns false.
  def with_migration_errors
    yield
    true
  rescue Accounting::QboMigration::Error, QuickbooksApiError, QuickbooksAuthError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
    false
  end

  def parse_cutover(value)
    value.present? ? Date.iso8601(value.to_s) : nil
  rescue Date::Error
    nil
  end

  def read_uploaded_text
    if params[:file].present? && params[:file].respond_to?(:read)
      params[:file].read.force_encoding('UTF-8')
    elsif params[:file_content].present?
      params[:file_content].to_s
    end
  end

  def build_config
    config = {}

    case params[:source_type]
    when 'quickbooks_desktop'
      if params[:file].present? && params[:file].respond_to?(:read)
        config['file_data'] = params[:file].read.force_encoding('UTF-8')
      elsif params[:file_content].present?
        config['file_data'] = params[:file_content].to_s
      elsif params[:parsed_data].present?
        config['parsed_data'] = params[:parsed_data].to_unsafe_h
      end
    when 'csv'
      config['data']     = params[:data].to_unsafe_h     if params[:data].present?
      config['mappings'] = params[:mappings].to_unsafe_h if params[:mappings].present?
    when 'freshbooks'
      config['access_token'] = params[:access_token]
      config['account_id']   = params[:account_id]
    end

    config
  end
end
