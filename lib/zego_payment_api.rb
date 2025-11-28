# frozen_string_literal: true

require 'xmlsimple'
require 'net/http'
require 'uri'

# Zego Payment API Service
#
# Adapted from RenterInsight's Zego integration to work with the new
# finance module. Handles payment processing, payment method management,
# and integration with Zego's payment gateway.
#
# Test Credit Cards:
#   Valid: 4111123412341230
#   Fraudulent: 4100000000000019
#   Standard: 4444444444444448 cvv: 123
#   Amex: 378282246310005
#
# Test Bank:
#   Routing: 011000028
#   Account: 0923641103
#
# Usage:
#   api = ZegoPaymentApi.new(company)
#   api.capture_payment(payment_method, payment)
#

class ZegoPaymentApi
  # Constants
  CODE_CANCELLED = 5
  CODE_RETURNED = 6
  API_PARTNER_ID = 2
  FAKE_ZEGO_PM_ID = "99999999" # For bypassing Zego in test/dev
  
  attr_accessor :response, :response_data, :log, :company
  
  def initialize(company = nil)
    @company = company
    @response = nil
    @response_data = nil
    @log = nil
  end
  
  # ========================================
  # CONFIGURATION & CREDENTIALS
  # ========================================
  
  def api_partner_id
    API_PARTNER_ID
  end
  
  def requires_token_creation
    false
  end
  
  def api_url
    Setting.get_with_fallback('zego_api_url', @company&.id) || 
      Rails.application.credentials.dig(:zego, :url) ||
      'https://secure.paylease.com/PayLeaseGateway'
  end
  
  def admin_api_url
    Setting.get_with_fallback('zego_admin_url', @company&.id) ||
      Rails.application.credentials.dig(:zego, :admin_url) ||
      'https://secure.paylease.com/SmartMove'
  end
  
  # Get gateway credentials from settings with fallback to Rails credentials
  def gateway_options
    {
      gateway_id: Setting.get_with_fallback('zego_gateway_id', @company&.id) ||
                  Rails.application.credentials.dig(:zego, :gateway_id),
      login: Setting.get_with_fallback('zego_login', @company&.id) ||
             Rails.application.credentials.dig(:zego, :login),
      password: Setting.get_with_fallback('zego_password', @company&.id) ||
                Rails.application.credentials.dig(:zego, :password),
      admin_api_key: Setting.get_with_fallback('zego_admin_api_key', @company&.id) ||
                     Rails.application.credentials.dig(:zego, :admin_api_key),
      admin_username: Setting.get_with_fallback('zego_admin_username', @company&.id) ||
                      Rails.application.credentials.dig(:zego, :admin_username),
      admin_password: Setting.get_with_fallback('zego_admin_password', @company&.id) ||
                      Rails.application.credentials.dig(:zego, :admin_password),
      test: !Rails.env.production?
    }
  end
  
  # ========================================
  # API CALL HANDLING
  # ========================================
  
  # Make API call to Zego payment gateway
  def make_call(request, action, parameters = nil)
    api_initialize(true, request&.remote_ip)
    
    @log.save if @log # Generate log ID for tracing
    
    post_data = self.post_data(action, parameters)
    xml_post_data = self.to_xml(post_data)
    
    api_start(action, self.api_url, self.to_xml(self.clean_request(post_data)))
    
    begin
      uri = URI(self.api_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.scheme == 'https'
      http.read_timeout = 30
      http.open_timeout = 30
      
      # Create POST request with proper headers
      post_request = Net::HTTP::Post.new(uri.request_uri)
      post_request['Content-Type'] = 'application/x-www-form-urlencoded'
      post_request.body = "XML=#{xml_post_data}"
      
      self.response = http.request(post_request)
      
      @response_data = XmlSimple.xml_in(self.response.body)
      
      if self.response.present? && self.response.code == '200' && @response_data['Errors'].nil?
        api_success(self.response.body, true)
        return @response_data
      else
        api_failure(self.response.body)
        return false
      end
      
    rescue => e
      error_message = "#{e.message}\n#{e.backtrace.first}"
      error_message += "\n\nResponse Body:\n#{self.response.body}" if self.response.present?
      
      api_error(error_message)
      self.response = error_message
      
      return false
    end
  end
  
  # Make admin API call to Zego
  def make_admin_call(request, action, parameters = nil)
    api_initialize(true, request&.remote_ip)
    
    @log.save if @log # Generate log ID for tracing
    
    post_data = self.admin_post_data(action, parameters)
    xml_post_data = self.admin_to_xml(post_data)
    
    api_start(action, self.admin_api_url, self.admin_to_xml(self.clean_request(post_data)))
    
    begin
      uri = URI(self.admin_api_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.scheme == 'https'
      http.read_timeout = 30
      http.open_timeout = 30
      
      # Create POST request with proper headers  
      post_request = Net::HTTP::Post.new(uri.request_uri)
      post_request['Content-Type'] = 'application/x-www-form-urlencoded'
      post_request.body = xml_post_data
      
      self.response = http.request(post_request)
      
      @response_data = XmlSimple.xml_in(self.response.body)
      
      if self.response.present? && self.response.code == '200' && @response_data['Errors'].nil?
        api_success(self.response.body, true)
        return @response_data
      else
        api_failure(self.response.body)
        return false
      end
      
    rescue => e
      error_message = "#{e.message}\n#{e.backtrace.first}"
      error_message += "\n\nResponse Body:\n#{self.response.body}" if self.response.present?
      
      api_error(error_message)
      self.response = error_message
      
      return false
    end
  end
  
  # ========================================
  # XML HANDLING
  # ========================================
  
  # Convert hash to XML for regular API
  def to_xml(post)
    return XmlSimple.xml_out(
      recursive_compact(post.deep_dup),
      {
        NoAttr: true,
        NoEscape: true,
        RootName: 'PayLeaseGatewayRequest'
      }
    )
  end
  
  # Convert hash to XML for admin API
  def admin_to_xml(post)
    return XmlSimple.xml_out(
      recursive_compact(post.deep_dup),
      {
        NoAttr: false,
        AttrPrefix: true,
        NoEscape: true,
        RootName: 'PayLeaseRequest'
      }
    )
  end
  
  # Recursively remove nil values from hash/array
  def recursive_compact(value)
    if value.is_a?(Hash)
      value.each do |k, v|
        value[k] = recursive_compact(v)
      end
      value.compact
    elsif value.is_a?(Array)
      value.each_with_index do |v, index|
        value[index] = recursive_compact(v)
      end
      value
    else
      value
    end
  end
  
  # ========================================
  # RESPONSE PARSING
  # ========================================
  
  # Parse simple XML value from response data
  def read_simple_xml_value(data, element_path)
    element_path_parts = element_path.split('/')
    current_node = data
    
    element_path_parts.each do |element|
      return nil unless current_node.is_a?(Hash) || (current_node.is_a?(Array) && current_node.count == 1)
      
      if current_node.is_a?(Hash)
        current_node = current_node[element]
      elsif current_node.is_a?(Array) && current_node.count == 1
        current_node = current_node.first[element]
      end
    end
    
    return (current_node.is_a?(Array) && current_node.count == 1) ? current_node.first : current_node
  end
  
  def read_transaction_id
    read_simple_xml_value(self.response_data, 'Transactions/Transaction/TransactionId')
  end
  
  def read_transaction_code
    read_simple_xml_value(self.response_data, 'Transactions/Transaction/Code')
  end
  
  def read_transaction_message
    read_simple_xml_value(self.response_data, 'Transactions/Transaction/Message')
  end
  
  def read_gateway_payer_id
    read_simple_xml_value(self.response_data, 'Transactions/Transaction/GatewayPayerId')
  end
  
  def read_cash_card_number
    read_simple_xml_value(self.response_data, 'Transactions/Transaction/CardNumber')
  end
  
  def read_external_processing_fee
    0.0 # Zego doesn't return processing fee separately
  end
  
  # ========================================
  # STATUS HELPERS
  # ========================================
  
  def payment_success?
    success = self.response_data.present?
    
    if success
      status = read_simple_xml_value(self.response_data, 'Transactions/Transaction/Status')
      success = ['Success', 'Pending', 'Approved'].include?(status)
    end
    
    success
  end
  
  def payment_pending?
    success = self.response_data.present?
    
    if success
      status = read_simple_xml_value(self.response_data, 'Transactions/Transaction/Status')
      success = ['Pending'].include?(status)
    end
    
    success
  end
  
  def payment_error_message
    error_message = nil
    
    if !payment_success?
      if self.response_data.present?
        error_message = read_simple_xml_value(self.response_data, 'Transactions/Transaction/Message')
        
        if error_message.blank?
          errors = read_simple_xml_value(self.response_data, 'Errors/Error')
          error_message = errors.collect { |e| e['Message'] }.join(', ') if errors.is_a?(Array)
        else
          error_message = error_message.join(', ') if error_message.is_a?(Array)
        end
      end
      
      error_message ||= "Please contact Support."
      error_message = error_message.gsub('<', '').gsub('>', '') # Strip tags
    end
    
    error_message
  end
  
  # ========================================
  # HELPER METHODS
  # ========================================
  
  # Determine card type from card number
  def card_type_from_number(card_number)
    return 'Visa' if card_number.blank? || card_number[0] == '4'
    return 'Amex' if card_number[0] == '3'
    return 'MasterCard' if ['5', '2'].include?(card_number[0])
    return 'Discover' if card_number[0] == '6'
    'Visa' # Fallback
  end
  
  # Clean sensitive data from request for logging
  def clean_request(data)
    if data && Rails.env.production?
      sensitive_fields = [:RoutingNumber, :AccountNumber, :CreditCardNumber, 
                         :CreditCardExpMonth, :CreditCardExpYear, :CreditCardCvv2]
      
      sensitive_fields.each do |field|
        if data[:Transactions]&.dig(:Transaction, field)
          data[:Transactions][:Transaction][field] = "FILTERED"
        end
      end
      
      if data[:Credentials]&.dig(:Password)
        data[:Credentials][:Password] = "FILTERED"
      end
    end
    
    data
  end
  
  # ========================================
  # LOGGING HELPERS
  # ========================================
  
  def api_initialize(should_log = false, ip_address = nil)
    if should_log
      @log = ApiLog.new(
        company_id: @company&.id,
        ip_address: ip_address,
        provider: 'zego'
      )
    end
  end
  
  def api_start(action, url, request_body)
    return unless @log
    
    @log.assign_attributes(
      action: action,
      url: url,
      request: request_body,
      status: 'pending',
      started_at: Time.current
    )
    @log.save
  end
  
  def api_success(response_body, save_response = false)
    return unless @log
    
    @log.assign_attributes(
      response: save_response ? response_body : nil,
      status: 'success',
      completed_at: Time.current
    )
    @log.save
  end
  
  def api_failure(response_body)
    return unless @log
    
    @log.assign_attributes(
      response: response_body,
      status: 'failure',
      completed_at: Time.current
    )
    @log.save
  end
  
  def api_error(error_message)
    return unless @log
    
    @log.assign_attributes(
      response: error_message,
      status: 'error',
      completed_at: Time.current
    )
    @log.save
  end
  
  def api_call_success?
    @log&.status == 'success'
  end
  
  # ========================================
  # PAYMENT METHOD MANAGEMENT
  # ========================================
  
  # Create or update payment method account in Zego
  # Handles cash cards, ACH accounts, and credit cards
  def create_or_update_account(payment_method, id_field, request = nil)
    if payment_method.payment_type == 'cash'
      if payment_method[id_field].blank?
        self.issue_cash_card(payment_method, request)
      else
        return true # Cash card already issued
      end
    else
      # Create new account or update existing one
      if payment_method[id_field].blank? || API_PARTNER_ID != payment_method.api_partner_id
        self.create_account(payment_method, request)
      else
        # Zego requires remove + create to update
        if self.remove_account(payment_method, request)
          self.create_account(payment_method, request)
        end
      end
    end
    
    return self.payment_success?
  end
  
  # Create payment method account (ACH or Credit Card)
  def create_account(payment_method, request = nil)
    parameters = {
      payer_reference_id: payment_method.generate_reference_id,
      first_name: payment_method.billing_first_name,
      last_name: payment_method.billing_last_name
    }
    
    if payment_method.payment_type == 'ach'
      # ACH account creation
      parameters[:account_type] = (payment_method.ach_account_type || 'checking').titleize
      parameters[:routing_number] = payment_method.ach_routing_number
      parameters[:account_number] = payment_method.ach_account_number
      
      make_call(request, 'CreateBankPayerAccount', parameters)
    else
      # Credit card account creation
      exp_month = sprintf("%.2i", payment_method.credit_card_expires_on.month)
      exp_year = payment_method.credit_card_expires_on.year.to_s[2, 2]
      
      parameters[:address] = payment_method.billing_street
      parameters[:city] = payment_method.billing_city
      parameters[:state] = payment_method.billing_state
      parameters[:zip] = payment_method.billing_zip
      parameters[:country] = payment_method.billing_country.presence || 'US'
      
      parameters[:card_type] = self.card_type_from_number(payment_method.credit_card_number)
      parameters[:card_num] = payment_method.credit_card_number
      parameters[:card_exp_month] = exp_month
      parameters[:card_exp_year] = exp_year
      parameters[:card_code] = payment_method.credit_card_cvv
      parameters[:is_debit_card] = payment_method.debit_card?
      
      # No payment fields needed - just registering the card, not charging it
      # This avoids the $5 pre-auth charge that confuses customers
      
      make_call(request, 'CreateCardPayerAccount', parameters)
    end
    
    return self.payment_success?
  end
  
  # Remove payment method account from Zego
  def remove_account(payment_method, request = nil)
    parameters = {
      payer_reference_id: payment_method.generate_reference_id,
      gateway_payer_id: payment_method.external_id
    }
    
    make_call(request, 'RemovePayerAccount', parameters)
    return self.payment_success?
  end
  
  # Issue integrated cash rent card for resident
  def issue_cash_card(payment_method, request = nil)
    parameters = {
      payer_reference_id: payment_method.generate_reference_id,
      first_name: payment_method.billing_first_name,
      last_name: payment_method.billing_last_name,
      address: payment_method.billing_street,
      city: payment_method.billing_city,
      state: payment_method.billing_state,
      zip: payment_method.billing_zip,
      country: payment_method.billing_country.presence || 'US'
    }
    
    # Add property_id if resident has current lease
    if payment_method.resident&.current_lease&.property_id
      parameters[:property_id] = payment_method.resident.current_lease.property_id
    end
    
    # First call: SetResidents (admin API)
    post_data = self.admin_post_data('SetResidents', parameters)
    make_admin_call(request, 'SetResidents', post_data)
    
    # Second call: IssueIntegratedCashRentCard (regular API)
    make_call(request, 'IssueIntegratedCashRentCard', parameters)
    
    return self.payment_success?
  end
  
  # ========================================
  # PAYMENT PROCESSING
  # ========================================
  
  # Capture one-time payment
  def capture_one_time_payment(payment_method, payment, request = nil)
    capture_payment(payment_method, payment, request)
  end
  
  # Capture scheduled/recurring payment
  def capture_scheduled_payment(payment_method, payment, request = nil)
    capture_payment(payment_method, payment, request)
  end
  
  # Main payment capture logic
  # Handles regular payments, company payments, and screening fees
  def capture_payment(payment_method, payment, request = nil)
    payer_reference_id = payment_method.generate_reference_id
    
    # Determine gateway_payer_id and payee_id based on payment type
    gateway_payer_id = payment_method.external_id
    
    if payment.fee_type == 'screening_fee'
      # Screening fee payment - uses alternate external ID and company-level payee
      gateway_payer_id = payment_method.alternate_external_id
      payee_id = Setting.get_with_fallback('zego_payee_id', @company&.id) ||
                 Rails.application.credentials.dig(:zego, :payee_id)
      Rails.logger.info "[ZegoPaymentApi] Screening fee payment - using company payee_id: #{payee_id}"
    elsif payment.location_id.present?
      # Regular payment with location - MUST use location's operating account (no fallback)
      operating_account = payment.location.bank_accounts
        .where(account_purpose: 'operating')
        .first
      payee_id = operating_account&.external_id
      
      Rails.logger.info "[ZegoPaymentApi] Payment with location_id #{payment.location_id} - operating_account: #{operating_account&.id}, external_id: #{payee_id}"
      
      # NO FALLBACK - location must have valid bank account
      if payee_id.nil?
        error_msg = "Payment location (ID: #{payment.location_id}) has no operating bank account with external_id. Cannot process payment."
        Rails.logger.error "[ZegoPaymentApi] #{error_msg}"
        raise StandardError, error_msg
      end
    else
      # Payment has no location - this should not happen
      error_msg = "Payment (ID: #{payment.id}) has no location_id. Cannot determine payee account."
      Rails.logger.error "[ZegoPaymentApi] #{error_msg}"
      raise StandardError, error_msg
    end
    
    # CRITICAL: Ensure payee_id is present
    if payee_id.nil?
      error_msg = "Cannot process payment: payee_id is nil. Company ID: #{@company&.id}, Loan ID: #{payment.loan_id}"
      Rails.logger.error "[ZegoPaymentApi] #{error_msg}"
      raise StandardError, error_msg
    end
    
    # Build base parameters
    parameters = {
      payment_reference_id: payment.id,
      payer_reference_id: payer_reference_id,
      payee_id: payee_id,
      gateway_payer_id: gateway_payer_id,
      amount: payment.amount,
      fee: payment.processing_fee,
      fee_responsibility: payment.fee_responsibility,
      first_name: payment_method.billing_first_name,
      last_name: payment_method.billing_last_name
    }
    
    # Handle split deposits for loan payments with properties that use separate deposit accounts
    if payment.loan_id.present? && 
       payment.loan.present? && 
       payment.loan.respond_to?(:property) && 
       payment.loan.property.present? &&
       !payment.company.use_same_bank_account_for_deposits?
      
      # Determine distribution between operating and deposit accounts
      distributions = AccountingService.determine_distribution(
        payment.loan.lease,
        payment.amount,
        payment.payment_at
      )
      
      # Check if payment includes deposits that need to be split
      if distributions.keys.include?('deposits_held')
        deposit_account = payment.loan.property.bank_accounts
          .where(account_purpose: 'deposit')
          .first
        deposit_payee_id = deposit_account&.external_id
        
        if deposit_payee_id.present?
          deposit_amount = distributions['deposits_held']
          remaining_amount = payment.amount - deposit_amount
          
          # Create split deposit parameters
          parameters[:splits] = {
            deposit_payee_id => deposit_amount,
            payee_id => remaining_amount
          }
        end
      end
    end
    
    make_call(request, 'AccountPayment', parameters)
    
    return self.payment_success?
  end
  
  # ========================================
  # TRANSACTION MANAGEMENT
  # ========================================
  
  # Get transaction details from Zego
  def transaction_details(payment, request = nil)
    if payment.external_id.present?
      parameters = { transaction_id: payment.external_id }
    else
      parameters = { payment_reference_id: payment.hash_id }
    end
    
    return make_call(request, 'TransactionDetail', parameters)
  end
  
  # Void a transaction
  def void_transaction(payment, request = nil)
    parameters = { transaction_id: payment.external_id }
    return make_call(request, 'TransactionVoid', parameters)
  end
  
  # Refund a transaction
  def refund_transaction(payment, request = nil)
    parameters = {
      transaction_id: payment.external_id,
      refund_amount: payment.amount
    }
    make_call(request, 'TransactionRefund', parameters)
    return self.payment_success?
  end
  
  # Payout to ACH account (reverse payment)
  def payout_to_ach(payment_method, payout, request = nil)
    gateway_payer_id = payment_method.external_id
    payer_reference_id = payment_method.generate_reference_id
    
    operating_account = payout.property.bank_accounts
      .where(account_purpose: 'operating')
      .first
    payee_id = operating_account&.external_id
    
    parameters = {
      payment_reference_id: payout.id,
      payer_reference_id: payer_reference_id,
      payee_id: payee_id,
      gateway_payer_id: gateway_payer_id,
      amount: payout.amount
    }
    
    make_call(request, 'AccountPayDirect', parameters)
    
    return self.payment_success?
  end
  
  # ========================================
  # REPORTING & ADMIN METHODS
  # ========================================
  
  # Get ACH returns for date range
  def ach_returns(start_date, end_date, request = nil)
    parameters = {
      search_start_date: start_date.strftime("%m/%d/%Y"),
      search_end_date: end_date.strftime("%m/%d/%Y")
    }
    return make_call(request, 'ACHReturns', parameters)
  end
  
  # Get deposits by date range
  def deposit_by_date_range(start_date, end_date, request = nil)
    parameters = {
      search_start_date: start_date.strftime("%m/%d/%Y"),
      search_end_date: end_date.strftime("%m/%d/%Y")
    }
    return make_call(request, 'DepositsByDateRange', parameters)
  end
  
  # Ping Zego server to check status
  def server_status(request = nil)
    make_call(request, 'ServerPing')
  end
  
  # Check admin credentials
  def admin_check_credentials(request = nil)
    return make_admin_call(request, 'CheckCredentials', { PmID: @company.external_payments_id })
  end
  
  # Get transactions for a date
  def admin_get_transactions(request = nil)
    params = {
      PmID: @company.external_payments_id,
      Date: Date.today.strftime('%m/%d/%Y'),
      Status: 'INITIATED'
    }
    return make_admin_call(request, 'GetTransactions', params)
  end
  
  # Add property to Zego admin system
  def admin_add_property(property, request = nil)
    # Handle fake Zego PM ID for testing/bypass
    if @company.external_payments_id.present? && 
       @company.external_payments_id == FAKE_ZEGO_PM_ID
      
      # Emulate Zego response for testing
      fake_payees = property.bank_accounts
        .where(account_purpose: ['operating', 'deposit'])
        .collect do |bank_account|
          {
            PayeeId: FAKE_ZEGO_PM_ID,
            FieldName: "#{bank_account.account_purpose.titleize} Account",
            VarName: "#{bank_account.account_purpose}_#{bank_account.id}",
            BankAccountNumber: bank_account.account_number
          }
        end
      
      return {
        Action: [{ Payees: { Payee: fake_payees } }],
        Code: "1"
      }.deep_stringify_keys
    end
    
    # Build bank account parameters
    bank_account_params = property.bank_accounts
      .where(account_purpose: ['operating', 'deposit'])
      .collect do |bank_account|
        {
          BankName: "Bank Name",
          FieldName: "#{bank_account.account_purpose.titleize} Account",
          VarName: "#{bank_account.account_purpose}_#{bank_account.id}",
          BankAccountType: bank_account.account_type.titleize,
          BankAccountRouting: bank_account.routing_number,
          BankAccountNumber: bank_account.account_number
        }
      end
    
    params = {
      PmID: @company.external_payments_id,
      Property: {
        PropertyID: property.id,
        PropertyName: property.name,
        StreetAddress: property.street,
        City: property.city,
        State: property.state,
        PostalCode: property.zip,
        UnitCount: property.units.count,
        FreqID: 1,
        PaymentFields: { PaymentField: bank_account_params }
      }
    }
    
    return make_admin_call(request, 'AddProperty', params)
  end
  
  # Get properties from Zego admin system
  def admin_get_properties(request = nil)
    return make_admin_call(request, 'GetProperties', { PmID: @company.external_payments_id })
  end
  
  # Get payment methods for a property
  def admin_get_payment_methods(property_external_payments_id, request = nil)
    params = {
      PmID: @company.external_payments_id,
      PropertyReferenceID: property_external_payments_id
    }
    return make_admin_call(request, 'GetPaymentMethodsByProperty', params)
  end
  
  # ========================================
  # XML REQUEST BUILDERS
  # ========================================
  
  # Build post data for regular API calls
  # Constructs XML request structure based on action type
  def post_data(action, parameters = {})
    post = nil
    
    case action
    when 'AccountPayment'
      # Standard payment processing
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            PaymentReferenceId: parameters[:payment_reference_id],
            GatewayPayerId: parameters[:gateway_payer_id],
            PaymentTraceId: @log.id,
            PayeeId: parameters[:payee_id],
            PayerReferenceId: parameters[:payer_reference_id],
            TotalAmount: parameters[:fee_responsibility] == 'resident' ? 
                         parameters[:amount] + parameters[:fee] : 
                         parameters[:amount],
            FeeAmount: parameters[:fee_responsibility] == 'resident' ? 
                       parameters[:fee] : 0,
            IncurFee: parameters[:fee_responsibility] == 'resident' ? "No" : "Yes",
            CheckScanned: 'No'
          }
        }
      }
      
      # Add split deposit if present
      if parameters[:splits].present?
        splits = parameters[:splits].collect { |payee_id, amount| 
          { PayeeId: payee_id, Amount: amount } 
        }
        post[:Transactions][:Transaction][:SplitDeposit] = { Deposit: splits }
      end
      
    when 'CreateBankPayerAccount'
      # ACH account creation
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            PayerReferenceId: parameters[:payer_reference_id],
            PayerFirstName: parameters[:first_name],
            PayerLastName: parameters[:last_name],
            AccountType: parameters[:account_type],
            AccountFullName: "#{parameters[:first_name]} #{parameters[:last_name]}",
            RoutingNumber: parameters[:routing_number],
            AccountNumber: parameters[:account_number]
          }
        }
      }
      
    when 'CreateCardPayerAccount'
      # Credit card account creation - register payment method only (no charge)
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            PayerReferenceId: parameters[:payer_reference_id],
            PayerFirstName: parameters[:first_name],
            PayerLastName: parameters[:last_name],
            
            CreditCardType: parameters[:card_type],
            CreditCardNumber: parameters[:card_num],
            CreditCardExpMonth: parameters[:card_exp_month],
            CreditCardExpYear: parameters[:card_exp_year],
            CreditCardCvv2: parameters[:card_code],
            
            BillingFirstName: parameters[:first_name],
            BillingLastName: parameters[:last_name],
            BillingStreetAddress: parameters[:address],
            BillingCity: parameters[:city],
            BillingState: parameters[:state],
            BillingCountry: parameters[:country],
            BillingZip: parameters[:zip],
            IsDebitCard: parameters[:is_debit_card] ? "Yes" : "No"
            # No SaveAccount, CreditCardAction, PaymentReferenceId, PayeeId, or TotalAmount
            # Those are only for actual payment transactions
          }
        }
      }
      
    when 'SetResidents'
      # Admin API call for cash card setup
      # Get PM ID from settings/credentials
      pm_id = if @company.present? && @company.respond_to?(:external_payments_id) && @company.external_payments_id.present?
                @company.external_payments_id
              else
                Setting.get_with_fallback('zego_pm_id', @company&.id) ||
                  Rails.application.credentials.dig(:zego, :pm_id)
              end
      post = {
        PmID: pm_id,
        Residents: {
          Resident: {
            ResidentID: parameters[:payer_reference_id],
            PropertyID: parameters[:property_id],
            FirstName: parameters[:first_name],
            LastName: parameters[:last_name],
            
            StreetAddress: parameters[:address],
            City: parameters[:city],
            State: parameters[:state],
            Country: parameters[:country],
            PostalCode: parameters[:zip],
            Amount: 5, # Authorization amount
            Hold: false
          }
        }
      }
      
    when 'IssueIntegratedCashRentCard'
      # Cash card issuance
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            PayerReferenceId: parameters[:payer_reference_id],
            PayerFirstName: parameters[:first_name],
            PayerLastName: parameters[:last_name]
          }
        }
      }
      
    when 'RemovePayerAccount'
      # Remove payment method
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            PayerReferenceId: parameters[:payer_reference_id],
            GatewayPayerId: parameters[:gateway_payer_id]
          }
        }
      }
      
    when 'TransactionVoid'
      # Void transaction
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            TransactionId: parameters[:transaction_id]
          }
        }
      }
      
    when 'TransactionDetail'
      # Get transaction details
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action
          }
        }
      }
      
      # Add either transaction_id or payment_reference_id
      if parameters[:transaction_id].present?
        post[:Transactions][:Transaction][:TransactionId] = parameters[:transaction_id]
      end
      if parameters[:payment_reference_id].present?
        post[:Transactions][:Transaction][:PaymentReferenceId] = parameters[:payment_reference_id]
      end
      
    when 'TransactionRefund'
      # Refund transaction
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            TransactionId: parameters[:transaction_id],
            RefundAmount: parameters[:refund_amount]
          }
        }
      }
      
    when 'ACHReturns'
      # Get ACH returns
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            SearchStartDate: parameters[:search_start_date],
            SearchEndDate: parameters[:search_end_date]
          }
        }
      }
      
    when 'AccountPayDirect'
      # Direct payout to ACH
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            PaymentReferenceId: parameters[:payment_reference_id],
            PaymentTraceId: @log.id,
            PayerId: parameters[:payee_id],
            PayeeReferenceId: parameters[:payer_reference_id],
            GatewayPayeeId: parameters[:gateway_payer_id],
            TotalAmount: parameters[:amount]
          }
        }
      }
      
    when 'DepositsByDateRange'
      # Get deposits by date range
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action,
            SearchStartDate: parameters[:search_start_date],
            SearchEndDate: parameters[:search_end_date]
          }
        }
      }
      
    when 'ServerPing'
      # Server status check
      post = {
        Transactions: {
          Transaction: {
            TransactionAction: action
          }
        }
      }
    end
    
    # Add credentials to all requests
    post[:Credentials] = {
      GatewayId: gateway_options[:gateway_id],
      Username: gateway_options[:login],
      Password: gateway_options[:password]
    }
    
    # Add company-specific credentials if present
    # Use PM ID from settings/credentials (external_payments_id is legacy)
    pm_id = if @company.present? && @company.respond_to?(:external_payments_id) && @company.external_payments_id.present?
              @company.external_payments_id
            else
              Setting.get_with_fallback('zego_pm_id', @company&.id) ||
                Rails.application.credentials.dig(:zego, :pm_id)
            end
    
    if pm_id.present?
      post[:Credentials][:PmId] = pm_id
      post[:Credentials][:ApiKey] = gateway_options[:admin_api_key]
    end
    
    # Add mode (Test/Production)
    post[:Mode] = gateway_options[:test] ? 'Test' : 'Production'
    
    return post
  end
  
  # Build post data for admin API calls
  def admin_post_data(action, parameters = {})
    post = {}
    
    # Add credentials
    post[:Credentials] = {
      GatewayId: gateway_options[:gateway_id],
      Username: gateway_options[:admin_username],
      Password: gateway_options[:admin_password],
      ApiKey: gateway_options[:admin_api_key]
    }
    
    # Add mode
    post[:Mode] = gateway_options[:test] ? 'Test' : 'Production'
    
    # Add action with parameters
    post[:Action] = { '@Type': action }.merge(parameters || {})
    
    return post
  end
end
