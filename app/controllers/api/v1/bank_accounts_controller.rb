class Api::V1::BankAccountsController < ApplicationController
  before_action :set_company_scope
  before_action :set_location, if: -> { params[:location_id].present? }
  before_action :set_bank_account, only: [:show, :update, :destroy, :sync_to_zego, :update_display]

  # GET /api/v1/locations/:location_id/bank-accounts  (nested, Zego flow)
  # GET /api/v1/bank_accounts                          (top-level, company-wide)
  def index
    if @location
      return unless authorize_bank_account_access!('read')

      bank_accounts = @location.bank_accounts.where(is_deleted: [false, nil])
      render json: {
        bank_accounts: bank_accounts.map { |ba| format_bank_account(ba) },
        meta: { total: bank_accounts.count, location_id: @location.id }
      }
    else
      return unless authorize_action!('bank_accounts_accounting', 'read')

      accounts = company_scoped_bank_accounts
                   .includes(:location, :chart_of_account)
                   .order(:bank_name)

      render json: { bank_accounts: accounts.map { |ba| bank_account_json(ba) } }
    end
  end

  # GET /api/v1/locations/:location_id/bank_accounts/:id
  def show
    return unless authorize_bank_account_access!('read')
    
    render json: {
      bank_account: format_bank_account(@bank_account)
    }
  end

  # POST /api/v1/locations/:location_id/bank-accounts  (nested, Zego flow)
  # POST /api/v1/bank_accounts                          (top-level, sync_only / company-wide)
  def create
    if @location
      return unless authorize_bank_account_access!('create')

      bank_account = @location.bank_accounts.build(bank_account_params)
      bank_account.company = @company
      bank_account.created_by = current_user.id

      if bank_account.save
        render json: {
          bank_account: format_bank_account(bank_account),
          message: 'Bank account created successfully'
        }, status: :created
      else
        render json: { errors: bank_account.errors.full_messages }, status: :unprocessable_entity
      end
    else
      return unless authorize_action!('bank_accounts_accounting', 'create')

      bank_account = BankAccount.new(bank_account_params)
      bank_account.company_id = @company.id
      bank_account.created_by = current_user.id

      if bank_account.location_id.present? && !@company.locations.exists?(id: bank_account.location_id)
        return render json: { error: 'Location not found' }, status: :unprocessable_entity
      end

      if bank_account.save
        render json: bank_account_json(bank_account), status: :created
      else
        render json: { errors: bank_account.errors }, status: :unprocessable_entity
      end
    end
  end

  # PATCH /api/v1/locations/:location_id/bank-accounts/:id  (nested, Zego flow)
  # PATCH /api/v1/bank_accounts/:id                          (top-level, company-wide)
  def update
    if @location
      return unless authorize_bank_account_access!('update')
    else
      return unless authorize_action!('bank_accounts_accounting', 'update')
    end

    if @bank_account.locked? && params_contain_locked_fields?
      return render json: {
        error: "Cannot update account details after Zego sync. Contact Zego to make changes, then update display fields only."
      }, status: :unprocessable_entity
    end

    if @bank_account.update(bank_account_params)
      if @location
        render json: {
          bank_account: format_bank_account(@bank_account),
          message: 'Bank account updated successfully'
        }
      else
        render json: bank_account_json(@bank_account)
      end
    else
      render json: { errors: @bank_account.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/locations/:location_id/bank_accounts/:id/update_display
  # Location Admin+ can update display fields after Zego has been updated externally
  def update_display
    # Platform Admin OR Location Admin+ with RBAC
    return unless authorize_bank_account_access!('update')

    unless @bank_account.synced_to_zego?
      return render json: { error: "Account must be synced to Zego first" }, status: :unprocessable_entity
    end

    begin
      @bank_account.update_display_info!(
        last_four: params[:display_last_four],
        notes: params[:admin_notes]
      )
      render json: {
        bank_account: format_bank_account(@bank_account),
        message: 'Display info updated successfully'
      }
    rescue => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/locations/:location_id/bank_accounts/:id/sync_to_zego
  # Sync bank account to Zego and get PayeeId
  def sync_to_zego
    # Platform Admin OR Location Admin+ with RBAC
    return unless authorize_bank_account_access!('create')

    if @bank_account.synced_to_zego?
      return render json: { 
        error: "Account already synced to Zego",
        zego_payee_id: @bank_account.external_id 
      }, status: :unprocessable_entity
    end

    service = ZegoSyncService.new(@company)
    result = service.sync_location(@location)

    if result[:success]
      @bank_account.reload
      render json: {
        bank_account: format_bank_account(@bank_account),
        zego_payee_id: @bank_account.external_id,
        message: "Account synced to Zego successfully"
      }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/locations/:location_id/bank_accounts/:id
  def destroy
    # Platform Admin only
    return unless require_platform_admin!

    @bank_account.soft_delete!
    render json: { message: "Bank account deleted" }
  end

  # GET /api/v1/bank_accounts/check_enabled
  # Returns only bank accounts where check_printing_enabled = true.
  # Used by the check writing UI to populate the bank account dropdown.
  def check_enabled
    return unless authorize_action!('bank_accounts_accounting', 'read')

    accounts = company_scoped_bank_accounts
                 .where(check_printing_enabled: true)
                 .includes(:location, :chart_of_account)
                 .order(:bank_name)

    render json: { bank_accounts: accounts.map { |ba| bank_account_json(ba) } }
  end

  private

  def set_location
    @location = @company.locations.find(params[:location_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Location not found' }, status: :not_found
  end

  def set_bank_account
    @bank_account = if @location
                      @location.bank_accounts.find(params[:id])
                    else
                      company_scoped_bank_accounts.find(params[:id])
                    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Bank account not found' }, status: :not_found
  end

  # Bank accounts may be tagged directly with company_id OR scoped only via their
  # location's company. Top-level routes resolve through either path.
  def company_scoped_bank_accounts
    BankAccount
      .joins("LEFT JOIN locations ON locations.id = bank_accounts.location_id")
      .where("bank_accounts.company_id = ? OR locations.company_id = ?", @company.id, @company.id)
      .where(is_deleted: [false, nil])
  end

  def bank_account_params
    params.require(:bank_account).permit(
      :account_purpose,
      :account_type,
      :bank_name,
      :routing_number,
      :account_number,
      :account_holder_name,
      :display_last_four,
      :admin_notes,
      :location_id,
      :chart_of_account_id,
      :is_active,
      # Check printing fields
      :check_printing_enabled,
      :check_number,
      :check_format,
      :check_company_name,
      :check_company_street,
      :check_company_city,
      :check_company_state,
      :check_company_zip,
      :check_company_phone,
      :check_signor_name,
      :check_bank_name,
      :check_bank_city,
      :check_bank_state,
      :check_aba_fractional_number,
      :check_signature_heading
    )
  end

  def params_contain_locked_fields?
    locked_fields = ['routing_number', 'account_number', 'account_type', 'bank_name']
    params[:bank_account]&.keys&.any? { |key| locked_fields.include?(key) }
  end

  # Check if user can access bank accounts
  # Platform Admin always has access
  # OR check RBAC permissions for the location
  def authorize_bank_account_access!(action)
    # Platform Admin has full access
    return true if current_user.platform_admin?

    # Check RBAC - use 'payments' or 'bank_accounts' resource
    # Assuming you'll add this to RBAC system
    unless current_user.uses_rbac?
      render json: { error: 'Unauthorized' }, status: :forbidden
      return false  # CRITICAL FIX: Return false after rendering
    end

    # Check if user has permission for this location
    permission_service = PermissionService.new(current_user)
    
    # Check location access
    unless permission_service.accessible_location_ids.include?(@location.id)
      render json: { error: 'Access denied to this location' }, status: :forbidden
      return false  # CRITICAL FIX: Return false after rendering
    end

    # For now, allow location admins to manage bank accounts
    # You can add more granular RBAC checks here
    unless current_user.effective_admin?
      render json: { error: 'Location Admin or higher required' }, status: :forbidden
      return false  # CRITICAL FIX: Return false after rendering
    end

    true
  end

  # Top-level (company-wide) JSON shape, including Stripe feed fields and
  # chart-of-account linkage. Used by /api/v1/bank_accounts endpoints.
  def bank_account_json(ba)
    {
      id: ba.id,
      bank_name: ba.bank_name,
      account_type: ba.account_type,
      account_purpose: ba.account_purpose,
      masked_account_number: ba.masked_account_number,
      display_last_four: ba.display_last_four,
      routing_number: ba.routing_number.present? ? "****#{ba.routing_number[-4..]}" : nil,
      location_id: ba.location_id,
      location_name: ba.location&.name,
      chart_of_account_id: ba.chart_of_account_id,
      chart_of_account: ba.chart_of_account ? {
        id: ba.chart_of_account.id,
        account_number: ba.chart_of_account.account_number,
        name: ba.chart_of_account.name
      } : nil,
      stripe_fc_status: ba.stripe_fc_status,
      stripe_connected: ba.stripe_connected?,
      stripe_last_sync_at: ba.try(:stripe_fc_last_synced_at),
      institution_name: ba.try(:institution_name),
      transaction_count: ba.bank_transactions.count,
      is_active: ba.is_active,
      created_at: ba.created_at,
      # Check printing fields
      check_printing_enabled: ba.check_printing_enabled,
      check_number: ba.check_number,
      check_format: ba.check_format,
      check_company_name: ba.check_company_name,
      check_company_street: ba.check_company_street,
      check_company_city: ba.check_company_city,
      check_company_state: ba.check_company_state,
      check_company_zip: ba.check_company_zip,
      check_company_phone: ba.check_company_phone,
      check_signor_name: ba.check_signor_name,
      check_bank_name: ba.check_bank_name,
      check_bank_city: ba.check_bank_city,
      check_bank_state: ba.check_bank_state,
      check_aba_fractional_number: ba.check_aba_fractional_number,
      check_signature_heading: ba.check_signature_heading,
    }
  end

  def format_bank_account(bank_account)
    {
      id: bank_account.id,
      location_id: bank_account.location_id,
      account_type: bank_account.account_type,
      bank_name: bank_account.bank_name,
      masked_account_number: bank_account.masked_account_number,
      masked_routing_number: bank_account.masked_routing_number,
      display_last_four: bank_account.display_last_four,
      
      # Zego sync info
      zego_payee_id: bank_account.external_id, # PayeeId
      synced_to_zego: bank_account.synced_to_zego?,
      locked: bank_account.locked?,
      locked_at: bank_account.locked_at,
      
      # Admin info
      admin_notes: bank_account.admin_notes,
      
      # Full details (Platform Admin only)
      routing_number: current_user.platform_admin? ? bank_account.routing_number : nil,
      account_number: current_user.platform_admin? ? bank_account.account_number : nil,
      
      # Metadata
      created_at: bank_account.created_at,
      updated_at: bank_account.updated_at
    }
  end
end
