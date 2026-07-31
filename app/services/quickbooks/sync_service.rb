# frozen_string_literal: true

# Orchestrates DMS ↔ QuickBooks Online sync. Adapted from RI for dealer entities.
class Quickbooks::SyncService
  def initialize(connection)
    @connection = connection
    @company_id = connection.company_id
    @company    = Company.find(@company_id)
    @client     = Quickbooks::Client.new(connection)
    @start_date = connection.sync_start_date || Date.today
    @create_only = connection.sync_mode == 'create_only'
  end

  # ── Contacts → Customers ─────────────────────────────────────
  def sync_contacts(contact_ids: nil)
    log = start_log('Contact')
    synced = 0; failed = 0; skipped = 0; details = []

    contacts = @company.contacts
    contacts = contacts.where(id: contact_ids) if contact_ids.present?

    contacts.find_each do |contact|
      begin
        qb_id = QuickbooksEntityMapping.qb_id_for(@company_id, 'Contact', contact.id)
        if qb_id && @create_only
          skipped += 1
          next
        end

        customer_data = {
          'DisplayName'      => "#{contact.first_name} #{contact.last_name}".strip.truncate(100),
          'GivenName'        => contact.first_name,
          'FamilyName'       => contact.last_name,
          'PrimaryEmailAddr' => contact.email.present? ? { 'Address' => contact.email } : nil,
          'PrimaryPhone'     => contact.phone.present? ? { 'FreeFormNumber' => contact.phone } : nil,
          'CompanyName'      => contact.try(:company_name),
          'Active'           => true
        }.compact

        if qb_id
          existing = @client.find_customer(qb_id)
          customer_data['Id']        = qb_id
          customer_data['SyncToken'] = existing.dig('Customer', 'SyncToken')
          result = @client.update_customer(customer_data)
        else
          result = @client.create_customer(customer_data)
        end

        new_qb_id = result.dig('Customer', 'Id')
        QuickbooksEntityMapping.record_sync(@company_id, 'Contact', contact.id, 'Customer', new_qb_id)
        synced += 1
      rescue => e
        QuickbooksEntityMapping.record_error(@company_id, 'Contact', contact.id, e.message)
        details << { entity: "Contact##{contact.id}", error: e.message }
        failed += 1
      end
    end

    complete_log(log, synced, failed, skipped, details)
    { synced: synced, failed: failed, skipped: skipped }
  end

  # ── Suppliers → Vendors ───────────────────────────────────────
  def sync_suppliers(supplier_ids: nil)
    log = start_log('Supplier')
    synced = 0; failed = 0; skipped = 0; details = []

    suppliers = @company.suppliers
    suppliers = suppliers.where(id: supplier_ids) if supplier_ids.present?

    suppliers.find_each do |supplier|
      begin
        qb_id = QuickbooksEntityMapping.qb_id_for(@company_id, 'Supplier', supplier.id)
        if qb_id && @create_only
          skipped += 1
          next
        end

        vendor_data = {
          'DisplayName'      => supplier.name.truncate(100),
          'PrimaryEmailAddr' => supplier.try(:email).present? ? { 'Address' => supplier.email } : nil,
          'PrimaryPhone'     => supplier.try(:phone).present? ? { 'FreeFormNumber' => supplier.phone } : nil,
          'Active'           => true
        }.compact

        if qb_id
          vendor_data['Id'] = qb_id
          result = @client.update_vendor(vendor_data)
        else
          result = @client.create_vendor(vendor_data)
        end

        new_qb_id = result.dig('Vendor', 'Id')
        QuickbooksEntityMapping.record_sync(@company_id, 'Supplier', supplier.id, 'Vendor', new_qb_id)
        synced += 1
      rescue => e
        QuickbooksEntityMapping.record_error(@company_id, 'Supplier', supplier.id, e.message)
        details << { entity: "Supplier##{supplier.id}", error: e.message }
        failed += 1
      end
    end

    complete_log(log, synced, failed, skipped, details)
    { synced: synced, failed: failed, skipped: skipped }
  end

  # ── DMS Invoices → QB Invoices ────────────────────────────────
  def sync_invoices(since: 30.days.ago)
    log = start_log('Invoice')
    synced = 0; failed = 0; skipped = 0; details = []
    effective_since = [@start_date, since.to_date].max

    invoices = @company.invoices.where('created_at >= ?', effective_since)

    invoices.find_each do |invoice|
      begin
        qb_id = QuickbooksEntityMapping.qb_id_for(@company_id, 'Invoice', invoice.id)
        if qb_id && @create_only
          skipped += 1
          next
        end

        contact_id = invoice.try(:contact_id) || invoice.try(:customer_id)
        next unless contact_id

        customer_qb_id = QuickbooksEntityMapping.qb_id_for(@company_id, 'Contact', contact_id)
        unless customer_qb_id
          sync_contacts(contact_ids: [contact_id])
          customer_qb_id = QuickbooksEntityMapping.qb_id_for(@company_id, 'Contact', contact_id)
        end
        next unless customer_qb_id

        invoice_data = build_qb_invoice(invoice, customer_qb_id)

        if qb_id
          existing = @client.find_invoice(qb_id)
          invoice_data['Id']        = qb_id
          invoice_data['SyncToken'] = existing.dig('Invoice', 'SyncToken')
          result = @client.update_invoice(invoice_data)
        else
          result = @client.create_invoice(invoice_data)
        end

        new_qb_id = result.dig('Invoice', 'Id')
        QuickbooksEntityMapping.record_sync(@company_id, 'Invoice', invoice.id, 'Invoice', new_qb_id)
        synced += 1
      rescue => e
        QuickbooksEntityMapping.record_error(@company_id, 'Invoice', invoice.id, e.message)
        details << { entity: "Invoice##{invoice.id}", error: e.message }
        failed += 1
      end
    end

    complete_log(log, synced, failed, skipped, details)
    { synced: synced, failed: failed, skipped: skipped }
  end

  # ── COA Sync (DMS ↔ QB) ──────────────────────────────────────
  def sync_chart_of_accounts
    log = start_log('ChartOfAccount')
    synced = 0; failed = 0; details = []

    @company.chart_of_accounts.active.postable.order(:account_number).each do |account|
      begin
        next if account.qbo_account_id.present?

        result = @client.query("SELECT * FROM Account WHERE Name = '#{account.name.gsub("'", "\\\\'")}'")
        existing = result.dig('QueryResponse', 'Account')&.first

        if existing
          account.update!(qbo_account_id: existing['Id'])
          QuickbooksEntityMapping.record_sync(@company_id, 'ChartOfAccount', account.id, 'Account', existing['Id'])
        else
          qb_account_data = {
            'Name'           => account.name.truncate(100),
            'AccountType'    => map_account_type_to_qb(account.account_type, account.sub_type),
            'AccountSubType' => map_sub_type_to_qb(account.sub_type),
            'AcctNum'        => account.account_number
          }
          result = @client.create_account(qb_account_data)
          new_qb_id = result.dig('Account', 'Id')
          if new_qb_id
            account.update!(qbo_account_id: new_qb_id)
            QuickbooksEntityMapping.record_sync(@company_id, 'ChartOfAccount', account.id, 'Account', new_qb_id)
          end
        end
        synced += 1
      rescue => e
        QuickbooksEntityMapping.record_error(@company_id, 'ChartOfAccount', account.id, e.message)
        details << { entity: "Account##{account.id} #{account.name}", error: e.message }
        failed += 1
      end
    end

    complete_log(log, synced, failed, 0, details)
    { synced: synced, failed: failed }
  end

  # ── Fetch QB Accounts (for mapping UI) ────────────────────────
  def fetch_qb_accounts
    result = @client.query_accounts
    accounts = result.dig('QueryResponse', 'Account') || []

    accounts.map { |a|
      { id: a['Id'], name: a['FullyQualifiedName'] || a['Name'], type: a['AccountType'], sub_type: a['AccountSubType'] }
    }.sort_by { |a| a[:name] }
  end

  private

  def build_qb_invoice(invoice, customer_qb_id)
    lines = (invoice.try(:invoice_items) || []).map.with_index do |item, idx|
      {
        'LineNum'     => idx + 1,
        'Amount'      => (item.try(:total) || item.try(:amount) || 0).to_f.round(2),
        'DetailType'  => 'SalesItemLineDetail',
        'Description' => item.try(:description),
        'SalesItemLineDetail' => {
          'UnitPrice' => (item.try(:rate) || item.try(:unit_price) || 0).to_f.round(2),
          'Qty'       => item.try(:quantity) || 1
        }
      }
    end

    {
      'CustomerRef' => { 'value' => customer_qb_id },
      'TxnDate'     => (invoice.try(:invoice_date) || invoice.created_at.to_date).strftime('%Y-%m-%d'),
      'DueDate'     => (invoice.try(:due_date) || invoice.created_at.to_date + 30.days).strftime('%Y-%m-%d'),
      'Line'        => lines,
      'DocNumber'   => invoice.try(:invoice_number),
      'PrivateNote' => "Synced from #{Brand.current.name} DMS"
    }
  end

  def map_account_type_to_qb(account_type, sub_type)
    case account_type
    when 'asset'
      case sub_type
      when 'bank' then 'Bank'
      when 'accounts_receivable' then 'Accounts Receivable'
      when 'fixed_asset' then 'Fixed Asset'
      else 'Other Current Asset'
      end
    when 'liability'
      case sub_type
      when 'accounts_payable' then 'Accounts Payable'
      when 'long_term_liability' then 'Long Term Liability'
      else 'Other Current Liability'
      end
    when 'equity'  then 'Equity'
    when 'revenue' then 'Income'
    when 'expense'
      sub_type == 'cost_of_goods_sold' ? 'Cost of Goods Sold' : 'Expense'
    else 'Expense'
    end
  end

  def map_sub_type_to_qb(sub_type)
    {
      'bank'                 => 'Checking',
      'accounts_receivable'  => 'AccountsReceivable',
      'accounts_payable'     => 'AccountsPayable',
      'inventory'            => 'Inventory',
      'cost_of_goods_sold'   => 'SuppliesMaterialsCogs',
      'operating_expense'    => 'OtherMiscellaneousExpense',
      'payroll_expense'      => 'PayrollExpenses',
      'sales_revenue'        => 'SalesOfProductIncome',
      'retained_earnings'    => 'RetainedEarnings',
      'owners_equity'        => 'OpeningBalanceEquity'
    }[sub_type] || 'OtherMiscellaneousExpense'
  end

  def start_log(entity_type)
    QuickbooksSyncLog.create!(
      company_id: @company_id,
      entity_type: entity_type,
      operation: 'sync',
      status: 'pending',
      started_at: Time.current
    )
  end

  def complete_log(log, synced, failed, skipped, details)
    log.mark_success!({ synced: synced, failed: failed, skipped: skipped, details: details.first(20) }.to_json)
  rescue => e
    begin
      log.mark_failed!(e.message)
    rescue StandardError
      nil
    end
  end
end
