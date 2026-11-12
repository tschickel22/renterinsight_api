# frozen_string_literal: true

class Api::V1::AccountingImportsController < ApplicationController
  before_action :set_company_scope
  # The QuickBooks switch is for company admins (and platform admins, who may
  # be impersonating one). Staff with accounting rights can't run it: it
  # rewrites the whole set of books. The frontend hides the entry the same
  # way (useQboSwitchAccess).
  before_action :require_company_admin!, only: %i[
    create_migration migration update_migration accounts suggest_accounts update_accounts
    banks update_banks create_banks uncleared update_uncleared migration_preview post_migration rollback_migration
    go_live bank_balances lists update_lists search_lists
  ]

  def index
    return unless authorize_action!('accounting', 'read')

    # import_config is left out: for a QuickBooks switch it holds the whole
    # QuickBooks company (accounts, lists, open items). migration marks the
    # rows the switch wizard opens.
    imports = @company.accounting_imports.recent
    render json: { items: imports.map do |i|
      i.as_json(except: :import_config).merge('migration' => i.migration?, 'trial' => i.migration? && i.import_config&.dig('trial') ? true : false)
    end }
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

    trial = ActiveModel::Type::Boolean.new.cast(params[:trial]) || false
    import = Accounting::QboMigration::Wizard.start!(company: @company, user: current_user, cutover_date: date, trial: trial)
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

  # POST /api/v1/accounting_imports/:id/banks/create
  # A bank account for every QuickBooks bank and card not matched yet, each
  # matched to it. Creates bank accounts, so it needs that permission too.
  def create_banks
    return unless authorize_action!('accounting', 'create')
    return unless authorize_action!('bank_accounts_accounting', 'create')
    return unless (wizard = load_wizard)

    result = nil
    with_migration_errors { result = wizard.create_bank_accounts! } or return
    render json: wizard.banks_json.merge(migration: wizard.migration_json, created: result[:created],
                                         matched_existing: result[:matched_existing])
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

  # POST /api/v1/accounting_imports/:id/uncleared/bank_balances
  # Statement balances on the cutover day from each connected bank feed.
  # Blank ones are filled in; banks still fetching come back 'pending'.
  def bank_balances
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    with_migration_errors { wizard.fetch_bank_balances! } or return
    render json: wizard.uncleared_json
  end

  # GET /api/v1/accounting_imports/:id/lists
  # Each QuickBooks customer and vendor with the record it links to, the lead
  # it converts, or Create new (Accounting::QboMigration::ListMatcher).
  def lists
    return unless authorize_action!('accounting', 'read')
    return unless (wizard = load_wizard)

    render json: wizard.lists_json
  end

  # PUT /api/v1/accounting_imports/:id/lists
  #   { choices: [{ kind, external_id, action: 'link' | 'new' | 'auto', type, id }] }
  def update_lists
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    choices = Array(params.permit(choices: %i[kind external_id action type id])[:choices]).map { |c| c.to_h.stringify_keys }
    with_migration_errors { wizard.update_list_choices!(choices) } or return
    render json: wizard.lists_json
  end

  # GET /api/v1/accounting_imports/:id/lists/search?kind=customers&q=smith
  def search_lists
    return unless authorize_action!('accounting', 'read')
    return unless (wizard = load_wizard)

    kind = params[:kind].to_s == 'vendors' ? 'vendors' : 'customers'
    render json: { results: wizard.list_matcher.search(kind, params[:q]) }
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

  # POST /api/v1/accounting_imports/:id/go_live { cutover_date, trial }
  # From a posted trial (E101): rolls the trial back and starts a new switch
  # at the new cutover with every account and bank match carried over, in one
  # transaction. trial: true updates the trial to a newer date instead.
  def go_live
    return unless authorize_action!('accounting', 'create')
    return unless (wizard = load_wizard)

    date = parse_cutover(params[:cutover_date])
    return render(json: { error: 'Choose a cutover date' }, status: :unprocessable_entity) unless date
    unless wizard.import.status == 'posted' && wizard.trial?
      return render(json: { error: 'Only a posted trial switch can be updated or taken live' }, status: :unprocessable_entity)
    end
    if date < wizard.cutover_date
      return render(json: { error: "The new cutover can't be before the trial's (#{wizard.cutover_date.iso8601})" },
                    status: :unprocessable_entity)
    end

    trial = ActiveModel::Type::Boolean.new.cast(params[:trial]) || false
    import = nil
    ActiveRecord::Base.transaction do
      Accounting::QboMigration::Rollback.new(wizard).run!(current_user)
      import = Accounting::QboMigration::Wizard.start!(company: @company, user: current_user, cutover_date: date,
                                                       trial: trial, from: wizard.import.reload)
    end
    render json: { migration: wizard_for(import).migration_json }, status: :created
  rescue Accounting::QboMigration::Error, QuickbooksApiError, QuickbooksAuthError, ActiveRecord::RecordInvalid => e
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
