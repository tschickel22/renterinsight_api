class Api::V1::BankAccountsController < ApplicationController
  before_action :set_company_scope
  before_action :set_location
  before_action :set_bank_account, only: [:show, :update, :destroy, :sync_to_zego, :update_display]

  # GET /api/v1/locations/:location_id/bank_accounts
  def index
    # RBAC or Platform Admin
    return unless authorize_bank_account_access!('read')

    bank_accounts = @location.bank_accounts.where(is_deleted: [false, nil])
    
    render json: {
      bank_accounts: bank_accounts.map { |ba| format_bank_account(ba) },
      meta: {
        total: bank_accounts.count,
        location_id: @location.id
      }
    }
  end

  # GET /api/v1/locations/:location_id/bank_accounts/:id
  def show
    return unless authorize_bank_account_access!('read')
    
    render json: {
      bank_account: format_bank_account(@bank_account)
    }
  end

  # POST /api/v1/locations/:location_id/bank_accounts
  def create
    # Platform Admin OR Location Admin+ with RBAC
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
  end

  # PATCH /api/v1/locations/:location_id/bank_accounts/:id
  def update
    return unless authorize_bank_account_access!('update')

    # Cannot update locked fields after Zego sync
    if @bank_account.locked?
      if params_contain_locked_fields?
        return render json: { 
          error: "Cannot update account details after Zego sync. Contact Zego to make changes, then update display fields only." 
        }, status: :unprocessable_entity
      end
    end

    if @bank_account.update(bank_account_params)
      render json: {
        bank_account: format_bank_account(@bank_account),
        message: 'Bank account updated successfully'
      }
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

  private

  def set_location
    @location = @company.locations.find(params[:location_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Location not found' }, status: :not_found
  end

  def set_bank_account
    @bank_account = @location.bank_accounts.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Bank account not found' }, status: :not_found
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
      :admin_notes
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
      return render json: { error: 'Unauthorized' }, status: :forbidden
    end

    # Check if user has permission for this location
    permission_service = PermissionService.new(current_user)
    
    # Check location access
    unless permission_service.accessible_location_ids.include?(@location.id)
      return render json: { error: 'Access denied to this location' }, status: :forbidden
    end

    # For now, allow location admins to manage bank accounts
    # You can add more granular RBAC checks here
    unless current_user.effective_admin?
      return render json: { error: 'Location Admin or higher required' }, status: :forbidden
    end

    true
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
