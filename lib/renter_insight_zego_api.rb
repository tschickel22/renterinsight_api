# Test CC 4111123412341230
# Fraudulent CC 4100000000000019
# CC 4444444444444448 cvv: 123
# Amex 378282246310005
# Routing: 011000028
# Account: 0923641103

require 'xmlsimple'

class RenterInsightZegoApi
  include ApiCallHelper

  CODE_CANCELLED = 5
  CODE_RETURNED = 6

  API_PARTNER_ID = 2
  FAKE_ZEGO_PM_ID = "99999999"

  def api_partner_id
    RenterInsightZegoApi::API_PARTNER_ID
  end

  def requires_token_creation
    false
  end

  def initialize(company = nil)
    @company = company
  end

  def api_url
    ENV['ZEGO_URL'] || Rails.application.credentials.dig(:zego, :url)
  end

  def admin_api_url
    ENV['ZEGO_ADMIN_URL'] || Rails.application.credentials.dig(:zego, :admin_url)
  end

  def create_or_update_account(payment_method, id_field, request = nil)

    if payment_method.method_type == 'cash'  # cash? method might not exist
      if payment_method[id_field].blank?
        self.issue_cash_card(payment_method, request)
      else
        return true
      end
    else
      # We can either update a valid Pay Lease account or create a new one
      if payment_method[id_field].blank? || RenterInsightZegoApi::API_PARTNER_ID != payment_method.api_partner_id
        self.create_account(payment_method, request)
      else
        # There is no update... just remove and create
        if self.remove_account(payment_method, request)
          self.create_account(payment_method, request)
        end
      end
    end

    return self.payment_success?
  end

  def capture_one_time_payment(payment_method, payment, request = nil)
    capture_payment(payment_method, payment, request)
  end

  # Portal one-time payment - no account creation, direct card charge
  def capture_portal_payment(payment_method, payment, request = nil)
    payer_reference_id = payment_method.generate_reference_id
    
    # Get location from payment
    location = payment.location if payment.respond_to?(:location)
    location ||= payment.payable.location if payment.respond_to?(:payable) && payment.payable.respond_to?(:location)
    
    # Get payee_id from location's operating bank account, with fallback
    payee_id = location&.bank_accounts&.where(account_purpose: BankAccount::ACCOUNT_PURPOSE_OPERATING)&.first&.external_id
    payee_id ||= ENV['ZEGO_PAYEE_ID'] || Rails.application.credentials.dig(:zego, :payee_id)

    parameters = {
      payment_reference_id: payment.id,
      payer_reference_id: payer_reference_id,
      payee_id: payee_id,
      amount: payment.amount,
      fee: payment.respond_to?(:processing_fee) ? payment.processing_fee : 0,
      fee_responsibility: payment.respond_to?(:fee_responsibility) ? payment.fee_responsibility : nil,
      first_name: payment_method.billing_first_name,
      last_name: payment_method.billing_last_name,
      address: payment_method.billing_street,
      city: payment_method.billing_city,
      state: payment_method.billing_state,
      zip: payment_method.billing_zip,
      country: payment_method.billing_country.present? ? payment_method.billing_country : StatesHelper::COUNTRY_CODE_US,
      card_type: card_type_from_number(payment_method.credit_card_number),
      card_num: payment_method.credit_card_number,
      card_exp_month: sprintf("%.2i", payment_method.credit_card_exp_month),
      card_exp_year: payment_method.credit_card_exp_year.to_s[-2..-1],
      card_code: payment_method.credit_card_cvv,
      is_debit_card: payment_method.is_debit_card
    }

    make_call(request, 'CardPayment', parameters)

    return self.payment_success?
  end

  # Portal payment with account saving - handles both ACH and Credit Card
  # Creates payment method in Zego AND processes payment in single call
  # Returns GatewayPayerId for saving to payment_method.external_id
  def capture_portal_payment_with_save(payment_method, payment, request = nil)
    payer_reference_id = payment_method.generate_reference_id
    
    # Get location from payment
    location = payment.location if payment.respond_to?(:location)
    location ||= payment.payable.location if payment.respond_to?(:payable) && payment.payable.respond_to?(:location)
    
    # Get payee_id from location's operating bank account, with fallback
    payee_id = location&.bank_accounts&.where(account_purpose: BankAccount::ACCOUNT_PURPOSE_OPERATING)&.first&.external_id
    payee_id ||= ENV['ZEGO_PAYEE_ID'] || Rails.application.credentials.dig(:zego, :payee_id)

    parameters = {
      payment_reference_id: payment.id,
      payer_reference_id: payer_reference_id,
      payee_id: payee_id,
      amount: payment.amount,
      fee: payment.respond_to?(:processing_fee) ? payment.processing_fee : 0,
      fee_responsibility: payment.respond_to?(:fee_responsibility) ? payment.fee_responsibility : nil,
      first_name: payment_method.billing_first_name,
      last_name: payment_method.billing_last_name
    }

    # Determine payment type and add appropriate fields
    if payment_method.ach?
      # ACH Payment with account creation
      parameters[:account_type] = (payment_method.ach_account_type || "checking").titleize
      parameters[:account_full_name] = "#{payment_method.billing_first_name} #{payment_method.billing_last_name}"
      parameters[:routing_number] = payment_method.ach_routing_number
      parameters[:account_number] = payment_method.ach_account_number

      make_call(request, 'ACHPayment', parameters)
    else
      # Credit Card Payment with account creation
      exp_month = sprintf("%.2i", payment_method.credit_card_exp_month)
      exp_year = payment_method.credit_card_exp_year.to_s[-2..-1]

      parameters[:address] = payment_method.billing_street
      parameters[:city] = payment_method.billing_city
      parameters[:state] = payment_method.billing_state
      parameters[:zip] = payment_method.billing_zip
      parameters[:country] = payment_method.billing_country.present? ? payment_method.billing_country : StatesHelper::COUNTRY_CODE_US
      parameters[:card_type] = card_type_from_number(payment_method.credit_card_number)
      parameters[:card_num] = payment_method.credit_card_number
      parameters[:card_exp_month] = exp_month
      parameters[:card_exp_year] = exp_year
      parameters[:card_code] = payment_method.credit_card_cvv
      parameters[:is_debit_card] = payment_method.is_debit_card
      parameters[:save_account] = true  # Save account for future payments

      make_call(request, 'CardPayment', parameters)
    end

    return self.payment_success?
  end

  def capture_scheduled_payment(payment_method, payment, request = nil)
    capture_payment(payment_method, payment, request)
  end

  def capture_payment(payment_method, payment, request)
    
    payer_reference_id = payment_method.generate_reference_id
    gateway_payer_id = payment_method.external_id
    
    # Get location from payment (different payment types store location differently)
    location = payment.location if payment.respond_to?(:location)
    location ||= payment.payable.location if payment.respond_to?(:payable) && payment.payable.respond_to?(:location)
    location ||= payment.property if payment.respond_to?(:property)
    
    # Get payee_id from location's operating bank account, with fallback
    payee_id = location&.bank_accounts&.where(account_purpose: BankAccount::ACCOUNT_PURPOSE_OPERATING)&.first&.external_id
    payee_id ||= ENV['ZEGO_PAYEE_ID'] || Rails.application.credentials.dig(:zego, :payee_id)

    parameters = { 
      payment_reference_id: payment.id,  
      payer_reference_id: payer_reference_id, 
      payee_id: payee_id, 
      gateway_payer_id: gateway_payer_id, 
      amount: payment.amount, 
      fee: payment.respond_to?(:processing_fee) ? payment.processing_fee : 0,
      fee_responsibility: payment.respond_to?(:fee_responsibility) ? payment.fee_responsibility : nil
    }

    # Only handle deposit splits for lease payments that have this feature enabled
    if payment.respond_to?(:lease) && payment.lease.present? && 
       payment.company.respond_to?(:use_same_bank_account_for_deposits) && 
       !payment.company.use_same_bank_account_for_deposits
      distributions = AccountingService.determine_distribution(payment.lease, payment.amount, payment.payment_at)

      # Do we need to split this payment?
      if distributions.keys.include?(Account::CODE_DEPOSITS_HELD)

        # Is it 100% deposit?  If so, don't split, just swap payee_id
        deposit_payee_id = payment.location&.bank_accounts&.where(account_purpose: BankAccount::ACCOUNT_PURPOSE_DEPOSIT)&.first&.external_id
        deposit_payee_id ||= ENV['ZEGO_PAYEE_ID'] || Rails.application.credentials.dig(:zego, :payee_id)

        deposit_amount = distributions[Account::CODE_DEPOSITS_HELD.to_i]
        remaining_amount = (payment.amount - deposit_amount)

        # Is the property paying this fee? If so, tack it onto remaining_amount
        if payment.fee_responsibility != Payment::RESPONSIBILITY_RESIDENT
          #remaining_amount += payment.processing_fee
        end

        parameters[:splits] = {deposit_payee_id => deposit_amount, payee_id => remaining_amount}

      end
    end

    parameters[:first_name] = payment_method.billing_first_name
    parameters[:last_name]  = payment_method.billing_last_name

    make_call(request, 'AccountPayment', parameters)

    return self.payment_success?

  end

  def create_account(payment_method, request)

    parameters = { payer_reference_id: payment_method.generate_reference_id, first_name: payment_method.billing_first_name, last_name: payment_method.billing_last_name}

    if payment_method.ach?
      parameters[:account_type] = (payment_method.ach_account_type || "checking").titleize
      parameters[:routing_number]= payment_method.ach_routing_number
      parameters[:account_number]= payment_method.ach_account_number

      make_call(request, 'CreateBankPayerAccount', parameters)
    else

      exp_month = sprintf("%.2i", payment_method.credit_card_exp_month)
      exp_year = payment_method.credit_card_exp_year.to_s[-2..-1]  # Last 2 digits

      parameters[:first_name] = payment_method.billing_first_name
      parameters[:last_name]  = payment_method.billing_last_name
      parameters[:address]    = payment_method.billing_street
      parameters[:city]       = payment_method.billing_city
      parameters[:state]      = payment_method.billing_state
      parameters[:zip]        = payment_method.billing_zip
      parameters[:country]    = !payment_method.billing_country.nil? && !payment_method.billing_country.blank? ? payment_method.billing_country : StatesHelper::COUNTRY_CODE_US

      parameters[:card_type]      = self.card_type_from_number(payment_method.credit_card_number)
      parameters[:card_num]       = payment_method.credit_card_number
      parameters[:card_exp_month] = exp_month
      parameters[:card_exp_year]  = exp_year
      parameters[:card_code]      = payment_method.credit_card_cvv
      parameters[:is_debit_card]  = payment_method.is_debit_card

      # No payment fields needed - just registering the card, not charging it
      # This avoids the $5 pre-auth charge that confuses customers

      make_call(request, 'CreateCardPayerAccount', parameters)
    end

    return self.payment_success?
  end

  def remove_account(payment_method, request)
    parameters = { payer_reference_id: payment_method.generate_reference_id, gateway_payer_id: payment_method.external_id}
    make_call(request, 'RemovePayerAccount', parameters)
    return self.payment_success?
  end

  def issue_cash_card(payment_method, request)
    parameters = { payer_reference_id: payment_method.generate_reference_id}

    parameters[:property_id]= payment_method.resident.current_lease.property_id
    parameters[:first_name] = payment_method.billing_first_name
    parameters[:last_name]  = payment_method.billing_last_name
    parameters[:address]    = payment_method.billing_street
    parameters[:city]       = payment_method.billing_city
    parameters[:state]      = payment_method.billing_state
    parameters[:zip]        = payment_method.billing_zip
    parameters[:country]    = !payment_method.billing_country.nil? && !payment_method.billing_country.blank? ? payment_method.billing_country : StatesHelper::COUNTRY_CODE_US

    post_data = self.post_data('SetResidents', parameters)

    # First, make the call to SetResidents
    make_admin_call(request, 'SetResidents', post_data)

    # Then, the issuance call
    make_call(request, 'IssueIntegratedCashRentCard', parameters)

    return self.payment_success?
  end

  def transaction_details(payment, request)
    if !payment.external_id.blank?
      parameters = { transaction_id: payment.external_id}
    else
      parameters = { payment_reference_id: payment.hash_id}
    end

    return make_call(request, 'TransactionDetail', parameters)
  end

  def void_transaction(payment, request)
    parameters = { transaction_id: payment.external_id }
    return make_call(request, 'TransactionVoid', parameters)
  end

  def ach_returns(start_date, end_date, request)
    parameters = { search_start_date: start_date.strftime("%m/%d/%Y"), search_end_date: end_date.strftime("%m/%d/%Y") }
    return make_call(request, 'ACHReturns', parameters)
  end

  def deposit_by_date_range(start_date, end_date, request = nil)
    parameters = { search_start_date: start_date.strftime("%m/%d/%Y"), search_end_date: end_date.strftime("%m/%d/%Y") }
    return make_call(request, 'DepositsByDateRange', parameters)
  end

  def refund_transaction(payment, request)
    parameters = { transaction_id: payment.external_id, refund_amount: payment.amount}
    make_call(request, 'TransactionRefund', parameters)
    return self.payment_success?
  end

  def payout_to_ach(payment_method, payout, request = nil)

    gateway_payer_id = payment_method.external_id
    payer_reference_id = payment_method.generate_reference_id
    payee_id = payout.location&.bank_accounts&.where(account_purpose: BankAccount::ACCOUNT_PURPOSE_OPERATING)&.first&.external_id
    payee_id ||= ENV['ZEGO_PAYEE_ID'] || Rails.application.credentials.dig(:zego, :payee_id)

    parameters = { payment_reference_id: payout.id,  payer_reference_id: payer_reference_id, payee_id: payee_id, gateway_payer_id: gateway_payer_id, amount: payout.amount}

    make_call(request, 'AccountPayDirect', parameters)

    return self.payment_success?

  end

  def server_status(request = nil)
    make_call(request, 'ServerPing')
  end

  def admin_check_credentials(request = nil)
    # Test pmid: '89525247'
    return make_admin_call(request, 'CheckCredentials', {PmID: @company.external_payments_id })
  end

  def admin_get_transactions(request = nil)
    # Old PM ID: 99845122
    params = {PmID: @company.external_payments_id, Date: Date.today.strftime('%m/%d/%Y'), Status: 'INITIATED'}
    return make_admin_call(request, 'GetTransactions', params)
  end

  def admin_add_property(location_or_property, request = nil)
    location = location_or_property

    # We have a special code we use to bypass Zego
    if @company.external_payments_id.present? && @company.external_payments_id == RenterInsightZegoApi::FAKE_ZEGO_PM_ID

      # If we are bypassing Zego, we do have to emulate their response
      fake_payees = location.bank_accounts.where(account_purpose: [BankAccount::ACCOUNT_PURPOSE_OPERATING, BankAccount::ACCOUNT_PURPOSE_DEPOSIT]).collect do | bank_account|
        {
          PayeeId: RenterInsightZegoApi::FAKE_ZEGO_PM_ID,
          FieldName: "#{bank_account.account_purpose.titleize} Account",
          VarName: "#{bank_account.account_purpose}_#{bank_account.id}",
          BankAccountNumber: bank_account.account_number
        }
      end

      return {Action: [{Payees: {Payee: fake_payees}}], Code: "1"}.deep_stringify_keys

    end

    params = {PmID: @company.external_payments_id}

    bank_account_params = location.bank_accounts.where(account_purpose: [BankAccount::ACCOUNT_PURPOSE_OPERATING, BankAccount::ACCOUNT_PURPOSE_DEPOSIT]).collect do | bank_account|
       {
        BankName: bank_account.bank_name || "Bank Name",
        FieldName: "#{bank_account.account_purpose.titleize} Account",
        VarName: "#{bank_account.account_purpose}_#{bank_account.id}",
        BankAccountType: bank_account.account_type.titleize,
        BankAccountRouting: bank_account.routing_number,
        BankAccountNumber: bank_account.account_number
       }
    end

    params[:Property] = {
      PropertyID: location.id,
      PropertyName: location.name,
      StreetAddress: location.address_line1,
        City: location.city,
        State: location.state,
        PostalCode: location.zip_code,
        UnitCount: 0,
        FreqID: 1,
      PaymentFields: {PaymentField: bank_account_params}
    }

    return make_admin_call(request, 'AddProperty', params)
  end

  def admin_get_properties(request = nil)
    return make_admin_call(request, 'GetProperties', {PmID: @company.external_payments_id })
  end

  def admin_get_payment_methods(property_external_payments_id, request = nil)
    return make_admin_call(request, 'GetPaymentMethodsByProperty', {PmID: @company.external_payments_id, PropertyReferenceID: property_external_payments_id })
  end

  def payment_error_message
    error_message = nil

    if !payment_success?
      if self.response_data.present?
        # Log full response for debugging
        Rails.logger.error("[ZEGO DEBUG] Full response_data: #{self.response_data.inspect}")
        
        error_message = read_simple_xml_value(self.response_data, 'Transactions/Transaction/Message')

        if error_message.blank?
          errors = read_simple_xml_value(self.response_data, 'Errors/Error')

          error_message = errors.collect{|e| e['Message']}.join(', ') if errors.is_a?(Array)
        else
          error_message = error_message.join(', ') if error_message.is_a?(Array)
        end
      end

      error_message ||= "Please contact Support."

      error_message = error_message.gsub('<', '').gsub('>', '') # Strip tags

    end

    return error_message
  end

  def payment_success?
    success = self.response_data.present?

    if success
      status = read_simple_xml_value(self.response_data, 'Transactions/Transaction/Status')

      success = ['Success', 'Pending', 'Approved'].include?(status)
    end

    return success
  end

  def payment_pending?
    success = self.response_data.present?

    if success
      status = read_simple_xml_value(self.response_data, 'Transactions/Transaction/Status')

      success = ['Pending'].include?(status)
    end

    return success
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
    0.0
  end

  def read_transaction_id
    read_simple_xml_value(self.response_data, 'Transactions/Transaction/TransactionId')
  end

  protected

  def gateway_options
    {
      gateway_id: ENV['ZEGO_GATEWAY_ID'] || Rails.application.credentials.dig(:zego, :gateway_id), # Also called Merchant ID
      login:  ENV['ZEGO_LOGIN'] || Rails.application.credentials.dig(:zego, :login),
      password:  ENV['ZEGO_PASSWORD'] || Rails.application.credentials.dig(:zego, :password),

      admin_api_key:  ENV['ZEGO_ADMIN_API_KEY'] || Rails.application.credentials.dig(:zego, :admin_api_key),
      admin_username:  ENV['ZEGO_ADMIN_USERNAME'] || Rails.application.credentials.dig(:zego, :admin_username),
      admin_password:  ENV['ZEGO_ADMIN_PASSWORD'] || Rails.application.credentials.dig(:zego, :admin_password),

      test: !Rails.env.production?
    }
  end

  def make_call(request, action, parameters = nil)
    api_initialize(true, request&.remote_ip)

    @log.save # Generate the log id for tracing purposes

    post_data = self.post_data(action, parameters)
    xml_post_data = self.to_xml(post_data)

    # Debug: Log the actual XML being sent
    Rails.logger.info("[ZEGO DEBUG] Actual XML being sent:")
    Rails.logger.info(xml_post_data)

    api_start(action, self.api_url, self.to_xml(self.clean_request(post_data)))

    begin
      uri = URI(self.api_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.scheme == 'https'

      post_request = Net::HTTP::Post.new(uri.request_uri)
      post_request['Content-Type'] = 'application/x-www-form-urlencoded'
      post_request.body = "XML=#{xml_post_data}"
      self.response = http.request(post_request)

      # ==================== RESPONSE DEBUG START ====================
      Rails.logger.info("")
      Rails.logger.info("[ZEGO ADMIN DEBUG] Response code: #{self.response.code}")
      Rails.logger.info("[ZEGO ADMIN DEBUG] Response body (first 1000 chars):")
      Rails.logger.info(self.response.body[0..1000])
      Rails.logger.info("[ZEGO ADMIN DEBUG] Is response HTML? #{self.response.body.include?('<html>') || self.response.body.include?('<!DOCTYPE')}")
      Rails.logger.info("[ZEGO ADMIN DEBUG] Is response XML? #{self.response.body.include?('<?xml')}")
      Rails.logger.info("=" * 80)
      # ==================== RESPONSE DEBUG END ====================

      @response_data = XmlSimple.xml_in(self.response.body)

      if self.response.present? && self.response.code == '200' && @response_data['Errors'].nil?
        api_success(self.response.body, true)
        return @response_data
      else
        api_failure(self.response.body)
        return false
      end

    rescue
      new_response = $!.message + "\n" + $!.backtrace.first + "\n\nResponse Body:\n#{self.response.body}"

      api_error(new_response)

      self.response = new_response

      return false
    end
  end

  def make_admin_call(request, action, parameters = nil)
    api_initialize(true, request&.remote_ip)

    @log.save # Generate the log id for tracing purposes

    post_data = self.admin_post_data(action, parameters)
    xml_post_data = self.admin_to_xml(post_data)

    # ==================== DEBUG LOGGING START ====================
    Rails.logger.info("=" * 80)
    Rails.logger.info("[ZEGO ADMIN DEBUG] Making admin API call")
    Rails.logger.info("[ZEGO ADMIN DEBUG] Action: #{action}")
    Rails.logger.info("[ZEGO ADMIN DEBUG] Admin API URL: #{self.admin_api_url}")
    Rails.logger.info("[ZEGO ADMIN DEBUG] Company: #{@company&.name} (ID: #{@company&.id})")
    Rails.logger.info("[ZEGO ADMIN DEBUG] Company PM ID: #{@company&.external_payments_id}")
    Rails.logger.info("")
    Rails.logger.info("[ZEGO ADMIN DEBUG] Actual XML being sent:")
    Rails.logger.info(xml_post_data)
    Rails.logger.info("=" * 80)
    # ==================== DEBUG LOGGING END ====================

    api_start(action, self.admin_api_url, self.admin_to_xml(self.clean_request(post_data)))

    begin
      uri = URI(self.admin_api_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.scheme == 'https'

      post_request = Net::HTTP::Post.new(uri.request_uri)
      post_request['Content-Type'] = 'application/x-www-form-urlencoded'
      post_request.body = "#{xml_post_data}"
      self.response = http.request(post_request)

      @response_data = XmlSimple.xml_in(self.response.body)

      if self.response.present? && self.response.code == '200' && @response_data['Errors'].nil?
        api_success(self.response.body, true)
        return @response_data
      else
        api_failure(self.response.body)
        return false
      end

    rescue
      new_response = $!.message + "\n" + $!.backtrace.first
      new_response += "\n\nResponse Body:\n#{self.response.body}" if self.response.present?

      api_error(new_response)

      self.response = new_response

      return false
    end
  end

  def post_data(action, parameters = {})


    # PaymentReferenceId - A unique id for this payment generated by your system. Maximum length: 30 characters.
    # PaymentTraceId - A unique id for this request, generated by your system, to avoid duplicate transactions. Same PaymentReferenceId and PaymentTranceId pair will only be processed once every 36 hours. When a request is declined, please provide a different PaymentTraceId for another attempt. Maximum length: 30 characters.
    # PayerReferenceId - A unique id for the payer generated by your system. Maximum length: 30 characters.
    post = nil

    if action == 'AccountPayment'
      # Handle fee responsibility (nil means location/tenant pays, not the payer)
      payer_pays_fee = parameters[:fee_responsibility] == 'payer' rescue false
      
      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :PaymentReferenceId => parameters[:payment_reference_id],
            :GatewayPayerId => parameters[:gateway_payer_id],
            :PaymentTraceId => @log.id,
            :PayeeId => parameters[:payee_id],
            :PayerReferenceId => parameters[:payer_reference_id],
            :TotalAmount => payer_pays_fee ? parameters[:amount] + parameters[:fee] : parameters[:amount],
            :FeeAmount => payer_pays_fee ? parameters[:fee] : 0,
            :IncurFee => payer_pays_fee ? "No" : "Yes",
            :CheckScanned => 'No'
          }
        }
      }

      if parameters[:splits].present?
        splits = parameters[:splits].collect{|payee_id, amount| {PayeeId: payee_id, Amount: amount} }
        post[:Transactions][:Transaction][:SplitDeposit] = {Deposit: splits}
      end

    elsif action == 'CreateBankPayerAccount'
      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :PayerReferenceId => parameters[:payer_reference_id],
            :PayerFirstName => parameters[:first_name],
            :PayerLastName => parameters[:last_name],
            :AccountType => parameters[:account_type],
            :AccountFullName => parameters[:first_name]+' '+parameters[:last_name],
            :RoutingNumber => parameters[:routing_number],
            :AccountNumber => parameters[:account_number]
          }
        }
      }
    elsif action == 'ACHPayment'
      # ACH Payment with account creation (SaveAccount: Yes)
      payer_pays_fee = parameters[:fee_responsibility] == 'payer' rescue false
      
      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :PaymentReferenceId => parameters[:payment_reference_id],
            :PaymentTraceId => @log.id,
            :PayerReferenceId => parameters[:payer_reference_id],
            :PayeeId => parameters[:payee_id],
            :PayerFirstName => parameters[:first_name],
            :PayerLastName => parameters[:last_name],
            
            :AccountType => parameters[:account_type],
            :AccountFullName => parameters[:account_full_name],
            :RoutingNumber => parameters[:routing_number],
            :AccountNumber => parameters[:account_number],
            
            :TotalAmount => payer_pays_fee ? parameters[:amount] + parameters[:fee] : parameters[:amount],
            :FeeAmount => payer_pays_fee ? parameters[:fee] : 0,
            :IncurFee => payer_pays_fee ? "No" : "Yes",
            :SaveAccount => "Yes",  # Save account for future payments
            :CheckScanned => 'No'
          }
        }
      }
    elsif action == 'CreateCardPayerAccount'
      # Register payment method only - no charge, no pre-auth
      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :PayerReferenceId => parameters[:payer_reference_id],
            :PayerFirstName => parameters[:first_name],
            :PayerLastName => parameters[:last_name],

            :CreditCardType => parameters[:card_type],
            :CreditCardNumber => parameters[:card_num],
            :CreditCardExpMonth => parameters[:card_exp_month],
            :CreditCardExpYear => parameters[:card_exp_year],
            :CreditCardCvv2 => parameters[:card_code],

            :BillingFirstName => parameters[:first_name],
            :BillingLastName => parameters[:last_name],
            :BillingStreetAddress => parameters[:address],
            :BillingCity => parameters[:city],
            :BillingState => parameters[:state],
            :BillingCountry => parameters[:country],
            :BillingZip => parameters[:zip],
            :IsDebitCard => (parameters[:is_debit_card] ? "Yes": "No")
            # No SaveAccount, CreditCardAction, PaymentReferenceId, PayeeId, or TotalAmount
            # Those are only for actual payment transactions
          }
        }
      }

    elsif action == 'CardPayment'
      # Card payment - can save account or be one-time based on parameter
      payer_pays_fee = parameters[:fee_responsibility] == 'payer' rescue false
      save_account = parameters[:save_account] == true ? "Yes" : "No"
      
      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :PaymentReferenceId => parameters[:payment_reference_id],
            :PaymentTraceId => @log.id,
            :PayerReferenceId => parameters[:payer_reference_id],
            :PayeeId => parameters[:payee_id],
            :PayerFirstName => parameters[:first_name],
            :PayerLastName => parameters[:last_name],

            :CreditCardType => parameters[:card_type],
            :CreditCardNumber => parameters[:card_num],
            :CreditCardExpMonth => parameters[:card_exp_month],
            :CreditCardExpYear => parameters[:card_exp_year],
            :CreditCardCvv2 => parameters[:card_code],

            :BillingFirstName => parameters[:first_name],
            :BillingLastName => parameters[:last_name],
            :BillingStreetAddress => parameters[:address],
            :BillingCity => parameters[:city],
            :BillingState => parameters[:state],
            :BillingCountry => parameters[:country],
            :BillingZip => parameters[:zip],
            :IsDebitCard => (parameters[:is_debit_card] ? "Yes": "No"),

            :TotalAmount => payer_pays_fee ? parameters[:amount] + parameters[:fee] : parameters[:amount],
            :FeeAmount => payer_pays_fee ? parameters[:fee] : 0,
            :IncurFee => payer_pays_fee ? "No" : "Yes",
            :SaveAccount => save_account
          }
        }
      }

    elsif action == 'SetResidents'
      post = {
        :PmID => @company.external_payments_id,
        :Residents => {
          :Resident => {
            :ResidentID => parameters[:payer_reference_id],
            :PropertyID => parameters[:property_id],
            :FirstName => parameters[:first_name],
            :LastName => parameters[:last_name],

            :StreetAddress => parameters[:address],
            :City => parameters[:city],
            :State => parameters[:state],
            :Country => parameters[:country],
            :PostalCode => parameters[:zip],
            :Amount => 5, # Just for Authorization
            :Hold => false
          }
        }
      }
    elsif action == 'IssueIntegratedCashRentCard'
      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :PayerReferenceId => parameters[:payer_reference_id],
            :PayerFirstName => parameters[:first_name],
            :PayerLastName => parameters[:last_name]
          }
        }
      }

    elsif action == 'RemovePayerAccount'
      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :PayerReferenceId => parameters[:payer_reference_id],
            :GatewayPayerId => parameters[:gateway_payer_id]
          }
        }
      }
    elsif action == 'TransactionVoid'

      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :TransactionId => parameters[:transaction_id],
          }
        }
      }
    elsif action == 'TransactionDetail'

      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action
          }
        }
      }

      post[:Transactions][:Transaction][:TransactionId] = parameters[:transaction_id] unless parameters[:transaction_id].blank?
      post[:Transactions][:Transaction][:PaymentReferenceId] = parameters[:payment_reference_id] unless parameters[:payment_reference_id].blank?

    elsif action == 'TransactionRefund'

      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :TransactionId => parameters[:transaction_id],
            :RefundAmount => parameters[:refund_amount]
          }
        }
      }

    elsif action == 'ACHReturns'

      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :SearchStartDate => parameters[:search_start_date],
            :SearchEndDate => parameters[:search_end_date]
          }
        }
      }

    elsif action == 'AccountPayDirect'
      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :PaymentReferenceId => parameters[:payment_reference_id],
            :PaymentTraceId => @log.id,
            :PayerId => parameters[:payee_id],
            :PayeeReferenceId => parameters[:payer_reference_id],
            :GatewayPayeeId => parameters[:gateway_payer_id],
            :TotalAmount => parameters[:amount]
          }
        }
      }
    elsif action == 'DepositsByDateRange'

      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action,
            :SearchStartDate => parameters[:search_start_date],
            :SearchEndDate => parameters[:search_end_date]
          }
        }
      }


    elsif action == 'ServerPing'
      post = {
        :Transactions => {
          :Transaction => {
            :TransactionAction => action
          }
        }
      }
    end

    post[:Credentials] = {
      GatewayId: gateway_options[:gateway_id],
      Username: gateway_options[:login],
      Password: gateway_options[:password]
    }

    # Debug logging for company context
    Rails.logger.info("[ZEGO DEBUG] @company present?: #{@company.present?}")
    Rails.logger.info("[ZEGO DEBUG] @company: #{@company.inspect}")
    Rails.logger.info("[ZEGO DEBUG] @company.external_payments_id: #{@company&.external_payments_id}")

    if @company.present?
      post[:Credentials][:PmId] = @company.external_payments_id
      post[:Credentials][:ApiKey] = gateway_options[:admin_api_key]
      Rails.logger.info("[ZEGO DEBUG] Added PmId and ApiKey to credentials")
    else
      Rails.logger.error("[ZEGO DEBUG] @company is nil - cannot add PmId/ApiKey!")
    end

    post[:Mode] = gateway_options[:test] ? 'Test' : 'Production'
    
    # Debug logging
    Rails.logger.info("[ZEGO DEBUG] Rails.env: #{Rails.env}")
    Rails.logger.info("[ZEGO DEBUG] Rails.env.production?: #{Rails.env.production?}")
    Rails.logger.info("[ZEGO DEBUG] gateway_options[:test]: #{gateway_options[:test]}")
    Rails.logger.info("[ZEGO DEBUG] Mode being sent: #{post[:Mode]}")
    Rails.logger.info("[ZEGO DEBUG] Final credentials: #{post[:Credentials].inspect}")

    return post
  end

  def admin_post_data(action, parameters = {})
    post = { }

    post[:Credentials] = {
      GatewayId: gateway_options[:gateway_id],
      Username: gateway_options[:admin_username],
      Password: gateway_options[:admin_password],
      ApiKey: gateway_options[:admin_api_key],
    }

    post[:Mode] = gateway_options[:test] ? 'Test' : 'Production'
    post[:Action] = {'@Type': action}.merge(parameters || {})

    return post
  end


  def to_xml(post)
    return XmlSimple.xml_out(recursive_compact(post.deep_dup), {:NoAttr => true, :NoEscape => true, :RootName=>'PayLeaseGatewayRequest'})
  end

  def admin_to_xml(post)
    return XmlSimple.xml_out(recursive_compact(post.deep_dup), {:NoAttr => false, :AttrPrefix => true, :NoEscape => true, :RootName=>'PayLeaseRequest'})
  end

  def recursive_compact(value)
    if value.is_a?(Hash)
      value.each do | k, v|
        value[k] = recursive_compact(v)
      end
      value.compact
    elsif value.is_a?(Array)
      value.each_with_index do | v, index |
        value[index] = recursive_compact(v)
      end
    else
      value
    end
  end

  def api_call_success?
    'success' == @log.status
  end

  def card_type_from_number(card_number)
    # Visa, MasterCard, Discover, Amex
    if card_number.blank? || card_number[0] == '4'
      return 'Visa'
    elsif card_number[0] == '3'
      return 'Amex'
    elsif card_number[0] == '5' || card_number[0] == '2'
      return 'MasterCard'
    elsif card_number[0] == '6'
      return 'Discover'
    else # As a fallback, return Visa--if it's invalid, PayLease will give us an error message to display to the user
      return 'Visa'
    end
  end

  def read_simple_xml_value(data, element_path)
    # Element path will be something like
    # policy_node_path/PolicyNumber
    element_path_parts = element_path.split('/')

    current_node = data

    element_path_parts.each do | element |

      return nil unless current_node.is_a?(Hash) || (current_node.is_a?(Array) && current_node.count == 1)

      if current_node.is_a?(Hash)
        current_node = current_node[element]
      elsif (current_node.is_a?(Array) && current_node.count == 1)
        current_node = current_node.first[element]
      end

    end

    return (current_node.is_a?(Array) && current_node.count == 1) ? current_node.first : current_node

  end

  def clean_request(data)
    if data && Rails.env.production?

      [:RoutingNumber, :AccountNumber, :CreditCardNumber, :CreditCardExpMonth, :CreditCardExpYear, :CreditCardCvv2].each do | field |
        data[:Transactions][:Transaction][field] = "FILTERED" if data[:Transactions] && data[:Transactions][:Transaction] && data[:Transactions][:Transaction][field]
      end

      data[:Credentials][:Password] = "FILTERED" if data[:Credentials] && data[:Credentials][:Password]

    end

    return data
  end

end
