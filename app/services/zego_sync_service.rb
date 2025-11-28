class ZegoSyncService
  attr_reader :company, :zego_api

  def initialize(company)
    @company = company
    @zego_api = RenterInsightZegoApi.new(company)
  end

  # Check if Zego credentials are valid
  def check_credentials
    Rails.logger.info "🔐 Checking Zego credentials for company: #{company.name}"
    
    unless company.external_payments_id.present?
      Rails.logger.error "❌ Company missing external_payments_id"
      return { success: false, error: "Company must have external_payments_id configured" }
    end

    result = zego_api.admin_check_credentials
    
    if result
      Rails.logger.info "✅ Zego credentials valid"
      { success: true, result: result }
    else
      Rails.logger.error "❌ Zego credentials invalid: #{zego_api.payment_error_message}"
      { success: false, error: zego_api.payment_error_message }
    end
  rescue => e
    Rails.logger.error "❌ Error checking credentials: #{e.message}"
    { success: false, error: e.message }
  end

  # Sync a location to Zego (creates property and gets PayeeIds)
  def sync_location(location)
    Rails.logger.info "🏢 Syncing location to Zego: #{location.name}"
    
    # Validate company has PM ID
    unless company.external_payments_id.present?
      Rails.logger.error "❌ Company missing external_payments_id"
      return { success: false, error: "Company must have external_payments_id configured" }
    end

    # Validate location has bank accounts
    bank_accounts = location.bank_accounts.where(is_deleted: [false, nil])
    if bank_accounts.empty?
      Rails.logger.error "❌ Location has no bank accounts"
      return { success: false, error: "Location must have at least one bank account" }
    end

    Rails.logger.info "📋 Found #{bank_accounts.count} bank account(s) for location"

    # Call Zego API to add property
    result = zego_api.admin_add_property(location)
    
    unless result
      Rails.logger.error "❌ Failed to add property to Zego: #{zego_api.payment_error_message}"
      return { success: false, error: zego_api.payment_error_message }
    end

    Rails.logger.info "🔗 Property added to Zego, processing PayeeIds..."

    # Extract PayeeIds from response and update bank accounts
    synced_count = 0
    
    if result['Action'] && result['Action'].is_a?(Array) && result['Action'][0]['Payees']
      # XmlSimple wraps Payees in an array
      payees_wrapper = result['Action'][0]['Payees']
      payees_wrapper = payees_wrapper[0] if payees_wrapper.is_a?(Array)
      payees = payees_wrapper['Payee']
      payees = [payees] unless payees.is_a?(Array)
      
      Rails.logger.info "📋 Received #{payees.count} PayeeId(s) from Zego"
      
      payees.each do |payee|
        # XmlSimple wraps values in arrays
        var_name = payee['VarName'].is_a?(Array) ? payee['VarName'][0] : payee['VarName']
        payee_id = payee['PayeeId'].is_a?(Array) ? payee['PayeeId'][0] : payee['PayeeId']
        
        # VarName format: "operating_123" or "deposit_456"
        if var_name =~ /^(operating|deposit)_(\d+)$/
          purpose = $1
          bank_account_id = $2.to_i
          
          bank_account = bank_accounts.find_by(id: bank_account_id, account_purpose: purpose)
          
          if bank_account
            bank_account.update!(
              external_id: payee_id,
              is_verified: true,
              verified_at: Time.current
            )
            synced_count += 1
            Rails.logger.info "✅ Updated #{purpose} account (ID: #{bank_account_id}) with PayeeId: #{payee_id}"
          else
            Rails.logger.warn "⚠️  Bank account not found for VarName: #{var_name}"
          end
        end
      end
    end

    # Update location with external property ID
    location.update!(external_payments_property_id: location.id.to_s)
    
    Rails.logger.info "✅ Location sync complete - #{synced_count} bank account(s) synced"
    
    {
      success: true,
      location: location.reload,
      synced_accounts: synced_count,
      result: result
    }
  rescue => e
    Rails.logger.error "❌ Error syncing location: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    { success: false, error: e.message }
  end

  # Get transactions for a specific date
  def get_transactions(date = Date.today)
    Rails.logger.info "📋 Fetching transactions for date: #{date}"
    
    unless company.external_payments_id.present?
      Rails.logger.error "❌ Company missing external_payments_id"
      return { success: false, error: "Company must have external_payments_id configured" }
    end

    result = zego_api.admin_get_transactions
    
    if result
      Rails.logger.info "✅ Transactions retrieved"
      { success: true, result: result }
    else
      Rails.logger.error "❌ Failed to get transactions: #{zego_api.payment_error_message}"
      { success: false, error: zego_api.payment_error_message }
    end
  rescue => e
    Rails.logger.error "❌ Error getting transactions: #{e.message}"
    { success: false, error: e.message }
  end

  # Get all properties from Zego
  def get_properties
    Rails.logger.info "📋 Fetching properties from Zego"
    
    unless company.external_payments_id.present?
      Rails.logger.error "❌ Company missing external_payments_id"
      return { success: false, error: "Company must have external_payments_id configured" }
    end

    result = zego_api.admin_get_properties
    
    if result
      Rails.logger.info "✅ Properties retrieved"
      { success: true, result: result }
    else
      Rails.logger.error "❌ Failed to get properties: #{zego_api.payment_error_message}"
      { success: false, error: zego_api.payment_error_message }
    end
  rescue => e
    Rails.logger.error "❌ Error getting properties: #{e.message}"
    { success: false, error: e.message }
  end

  # Check Zego server status
  def check_server_status
    Rails.logger.info "🔍 Checking Zego server status"
    
    result = zego_api.server_status
    
    if result
      Rails.logger.info "✅ Zego server is responding"
      { success: true, result: result }
    else
      Rails.logger.error "❌ Zego server not responding"
      { success: false, error: "Server not responding" }
    end
  rescue => e
    Rails.logger.error "❌ Error checking server status: #{e.message}"
    { success: false, error: e.message }
  end
end
