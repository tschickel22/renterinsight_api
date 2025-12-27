# frozen_string_literal: true

class QuickbooksApiService
  attr_reader :entity
  
  def initialize(entity)
    @entity = entity # Company or Location
  end
  
  # Company Info
  def get_company_info
    get("company/#{entity.quickbooks_realm_id}/companyinfo/#{entity.quickbooks_realm_id}")
  end
  
  # Items (Inventory)
  def create_item(item_data)
    post('item', { Item: item_data })
  end
  
  def update_item(qb_id, item_data)
    post('item', { Item: item_data.merge(Id: qb_id) }, sparse: true)
  end
  
  def get_item(qb_id)
    get("item/#{qb_id}")
  end
  
  def query_items(query = "SELECT * FROM Item")
    query(query)
  end
  
  # Customers
  def create_customer(customer_data)
    post('customer', { Customer: customer_data })
  end
  
  def update_customer(qb_id, customer_data)
    post('customer', { Customer: customer_data.merge(Id: qb_id) }, sparse: true)
  end
  
  def get_customer(qb_id)
    get("customer/#{qb_id}")
  end
  
  def query_customers(query = "SELECT * FROM Customer")
    query(query)
  end
  
  # Invoices
  def create_invoice(invoice_data)
    post('invoice', { Invoice: invoice_data })
  end
  
  def update_invoice(qb_id, invoice_data)
    post('invoice', { Invoice: invoice_data.merge(Id: qb_id) }, sparse: true)
  end
  
  def get_invoice(qb_id)
    get("invoice/#{qb_id}")
  end
  
  def query_invoices(query = "SELECT * FROM Invoice")
    query(query)
  end
  
  # Payments
  def create_payment(payment_data)
    post('payment', { Payment: payment_data })
  end
  
  def get_payment(qb_id)
    get("payment/#{qb_id}")
  end
  
  def query_payments(query = "SELECT * FROM Payment")
    query(query)
  end
  
  # Accounts (Chart of Accounts)
  def get_accounts
    query("SELECT * FROM Account WHERE Active = true")
  end
  
  def get_account(qb_id)
    get("account/#{qb_id}")
  end
  
  # Change Data Capture (CDC) for incremental sync
  def get_cdc(entities, changed_since)
    params = {
      entities: entities.join(','),
      changedSince: changed_since.iso8601
    }
    get('cdc', params)
  end
  
  private
  
  def get(path, params = {})
    url = "#{base_url}/#{path}"
    url += "?#{URI.encode_www_form(params)}" if params.any?
    
    response = HTTP.auth("Bearer #{access_token}")
      .headers(accept: 'application/json')
      .get(url)
    
    handle_response(response)
  end
  
  def post(path, body, sparse: false)
    url = "#{base_url}/#{path}"
    url += "?operation=sparse" if sparse
    
    response = HTTP.auth("Bearer #{access_token}")
      .headers(
        accept: 'application/json',
        content_type: 'application/json'
      )
      .post(url, json: body)
    
    handle_response(response)
  end
  
  def query(sql)
    get('query', { query: sql })
  end
  
  def handle_response(response)
    if response.status.success?
      data = JSON.parse(response.body.to_s)
      { success: true, data: data }
    else
      error_data = JSON.parse(response.body.to_s) rescue {}
      error_message = error_data.dig('Fault', 'Error', 0, 'Message') || 'Unknown error'
      { success: false, error: error_message, response: error_data }
    end
  rescue => e
    { success: false, error: e.message }
  end
  
  def base_url
    realm_id = entity.quickbooks_realm_id
    env = sandbox? ? 'sandbox-' : ''
    "https://#{env}quickbooks.api.intuit.com/v3/company/#{realm_id}"
  end
  
  def access_token
    crypt = ActiveSupport::MessageEncryptor.new(encryption_key)
    crypt.decrypt_and_verify(entity.quickbooks_access_token_encrypted)
  end
  
  def encryption_key
    Rails.application.key_generator.generate_key('quickbooks_tokens', 32)
  end
  
  def sandbox?
    Rails.application.credentials.dig(:quickbooks, :environment) == 'sandbox'
  end
end
