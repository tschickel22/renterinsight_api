# frozen_string_literal: true

module Accounting
  class ImportService
    def initialize(company, user)
      @company = company
      @user = user
    end

    def run_import!(source_type:, config: {}, cutover_date: nil, entities: nil)
      import_record = @company.accounting_imports.create!(
        user: @user,
        source_type: source_type,
        import_config: config,
        cutover_date: cutover_date || Date.current,
        status: 'pending'
      )

      import_record.mark_started!

      adapter = build_adapter(source_type, config)
      results = {}

      entities_to_import = entities || %w[chart_of_accounts contacts vendors opening_balances open_invoices]

      begin
        if entities_to_import.include?('chart_of_accounts')
          results[:chart_of_accounts] = import_chart_of_accounts(adapter, import_record)
        end

        if entities_to_import.include?('contacts')
          results[:contacts] = import_contacts(adapter, import_record)
        end

        if entities_to_import.include?('vendors')
          results[:vendors] = import_vendors(adapter, import_record)
        end

        if entities_to_import.include?('opening_balances')
          results[:opening_balances] = import_opening_balances(adapter, import_record, cutover_date || Date.current)
        end

        if entities_to_import.include?('open_invoices')
          results[:open_invoices] = import_open_invoices(adapter, import_record)
        end

        import_record.mark_completed!(results)
      rescue => e
        import_record.mark_failed!(e.message)
        Rails.logger.error("[AccountingImport] Failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        raise
      end

      { import_id: import_record.id, results: results }
    end

    def preview(source_type:, config: {})
      adapter = build_adapter(source_type, config)

      {
        source_type: source_type,
        available_data: {
          chart_of_accounts: adapter.count_accounts,
          contacts: adapter.count_contacts,
          vendors: adapter.count_vendors,
          open_invoices: adapter.count_open_invoices
        },
        existing_data: {
          chart_of_accounts: @company.chart_of_accounts.count,
          contacts: @company.contacts.count,
          suppliers: @company.suppliers.count
        }
      }
    rescue => e
      { error: e.message }
    end

    private

    def build_adapter(source_type, config)
      case source_type
      when 'quickbooks_online'
        connection = QuickbooksConnection.for_company(@company.id)
        raise "QuickBooks not connected" unless connection&.connected?
        Accounting::Adapters::QuickbooksOnlineAdapter.new(@company, connection, config)
      when 'quickbooks_desktop'
        raise "No file data provided" unless config['file_data'].present? || config['parsed_data'].present?
        Accounting::Adapters::QuickbooksDesktopAdapter.new(@company, config)
      when 'freshbooks'
        raise "Freshbooks not connected" unless config['access_token'].present?
        Accounting::Adapters::FreshbooksAdapter.new(@company, config)
      when 'csv'
        raise "No CSV data provided" unless config['data'].present?
        Accounting::Adapters::CsvAdapter.new(@company, config)
      else
        raise "Unknown source type: #{source_type}"
      end
    end

    def import_chart_of_accounts(adapter, import_record)
      imported = 0; skipped = 0; errors = 0

      accounts = adapter.fetch_accounts
      accounts.each do |acct_data|
        if acct_data[:account_number].present? &&
           @company.chart_of_accounts.exists?(account_number: acct_data[:account_number])
          skipped += 1
          next
        end

        if acct_data[:account_number].blank? &&
           @company.chart_of_accounts.exists?(name: acct_data[:name])
          skipped += 1
          next
        end

        account = @company.chart_of_accounts.build(
          account_number: acct_data[:account_number] || generate_account_number(acct_data[:account_type]),
          name: acct_data[:name],
          account_type: acct_data[:account_type],
          sub_type: acct_data[:sub_type],
          description: acct_data[:description],
          is_header: acct_data[:is_header] || false,
          is_active: acct_data.fetch(:is_active, true),
          qbo_account_id: acct_data[:external_id]
        )

        if account.save
          imported += 1
        else
          import_record.add_error('ChartOfAccount', acct_data[:name], account.errors.full_messages.join(', '))
          errors += 1
        end
      rescue => e
        import_record.add_error('ChartOfAccount', acct_data[:name], e.message)
        errors += 1
      end

      resolve_parent_relationships(adapter, accounts) if adapter.respond_to?(:parent_mappings)

      { imported: imported, skipped: skipped, errors: errors }
    end

    def import_contacts(adapter, import_record)
      imported = 0; skipped = 0; errors = 0

      contacts = adapter.fetch_contacts
      contacts.each do |contact_data|
        if contact_data[:email].present? && @company.contacts.exists?(email: contact_data[:email])
          skipped += 1
          next
        end

        if @company.contacts.where(first_name: contact_data[:first_name], last_name: contact_data[:last_name]).exists?
          skipped += 1
          next
        end

        contact = @company.contacts.build(
          first_name: contact_data[:first_name] || contact_data[:name]&.split(' ')&.first || 'Unknown',
          last_name: contact_data[:last_name] || contact_data[:name]&.split(' ', 2)&.last || '',
          email: contact_data[:email],
          phone: contact_data[:phone],
          company_name: contact_data[:company_name],
          street: contact_data[:street],
          city: contact_data[:city],
          state: contact_data[:state],
          zip: contact_data[:zip]
        )

        if contact.save
          imported += 1
        else
          import_record.add_error('Contact', "#{contact_data[:first_name]} #{contact_data[:last_name]}", contact.errors.full_messages.join(', '))
          errors += 1
        end
      rescue => e
        import_record.add_error('Contact', contact_data[:name] || contact_data[:email], e.message)
        errors += 1
      end

      { imported: imported, skipped: skipped, errors: errors }
    end

    def import_vendors(adapter, import_record)
      imported = 0; skipped = 0; errors = 0

      vendors = adapter.fetch_vendors
      vendors.each do |vendor_data|
        if @company.suppliers.where('LOWER(name) = ?', vendor_data[:name]&.downcase).exists?
          skipped += 1
          next
        end

        supplier = @company.suppliers.build(
          name: vendor_data[:name],
          email: vendor_data[:email],
          phone: vendor_data[:phone],
          address_line1: vendor_data[:street],
          city: vendor_data[:city],
          state: vendor_data[:state],
          zip_code: vendor_data[:zip],
          active: true
        )

        if supplier.save
          imported += 1
        else
          import_record.add_error('Supplier', vendor_data[:name], supplier.errors.full_messages.join(', '))
          errors += 1
        end
      rescue => e
        import_record.add_error('Supplier', vendor_data[:name], e.message)
        errors += 1
      end

      { imported: imported, skipped: skipped, errors: errors }
    end

    def import_opening_balances(adapter, import_record, cutover_date)
      balances = adapter.fetch_account_balances(cutover_date)
      return { imported: 0, skipped: 0, errors: 0, message: 'No balances available' } if balances.empty?

      posting_service = Accounting::ManualPostingService.new(@company)
      lines = []

      balances.each do |bal|
        account = if bal[:external_id].present?
                    @company.chart_of_accounts.find_by(qbo_account_id: bal[:external_id])
                  end
        account ||= @company.chart_of_accounts.find_by(account_number: bal[:account_number])
        account ||= @company.chart_of_accounts.find_by(name: bal[:account_name])

        next unless account
        next if bal[:balance].nil? || bal[:balance].zero?

        if account.normal_balance == 'debit'
          if bal[:balance] >= 0
            lines << { chart_of_account_id: account.id, debit_amount: bal[:balance].abs, credit_amount: 0, memo: "Opening balance — #{account.name}" }
          else
            lines << { chart_of_account_id: account.id, debit_amount: 0, credit_amount: bal[:balance].abs, memo: "Opening balance — #{account.name}" }
          end
        else
          if bal[:balance] >= 0
            lines << { chart_of_account_id: account.id, debit_amount: 0, credit_amount: bal[:balance].abs, memo: "Opening balance — #{account.name}" }
          else
            lines << { chart_of_account_id: account.id, debit_amount: bal[:balance].abs, credit_amount: 0, memo: "Opening balance — #{account.name}" }
          end
        end
      end

      if lines.any?
        total_debits = lines.sum { |l| l[:debit_amount] }
        total_credits = lines.sum { |l| l[:credit_amount] }
        diff = total_debits - total_credits

        if diff != 0
          obe_account = @company.chart_of_accounts.find_by(account_number: '3000') ||
                        @company.chart_of_accounts.find_by(name: "Owner's Equity / Capital") ||
                        @company.chart_of_accounts.where(account_type: 'equity').first

          if obe_account
            if diff > 0
              lines << { chart_of_account_id: obe_account.id, debit_amount: 0, credit_amount: diff.abs, memo: "Opening Balance Equity" }
            else
              lines << { chart_of_account_id: obe_account.id, debit_amount: diff.abs, credit_amount: 0, memo: "Opening Balance Equity" }
            end
          end
        end

        je = posting_service.post_complex!(
          lines: lines,
          memo: "Opening balances imported from #{adapter.source_name} as of #{cutover_date}",
          entry_date: cutover_date,
          posted_by: @user
        )

        if je
          { imported: lines.count, skipped: 0, errors: 0, journal_entry_id: je.id }
        else
          import_record.add_error('OpeningBalances', 'JournalEntry', 'Failed to create opening balance entry')
          { imported: 0, skipped: 0, errors: 1 }
        end
      else
        { imported: 0, skipped: 0, errors: 0, message: 'No accounts matched for balances' }
      end
    end

    def import_open_invoices(adapter, import_record)
      imported = 0; skipped = 0; errors = 0

      invoices = adapter.fetch_open_invoices
      invoices.each do |inv_data|
        if inv_data[:invoice_number].present? && @company.invoices.exists?(invoice_number: inv_data[:invoice_number])
          skipped += 1
          next
        end

        contact = find_or_skip_contact(inv_data[:customer_name], inv_data[:customer_email])

        invoice = @company.invoices.build(
          invoice_number: inv_data[:invoice_number],
          invoice_date: inv_data[:date],
          due_date: inv_data[:due_date],
          subtotal: inv_data[:amount],
          tax_amount: inv_data[:tax] || 0,
          total: inv_data[:total] || inv_data[:amount],
          amount_due: inv_data[:balance] || inv_data[:amount],
          amount_paid: (inv_data[:total] || inv_data[:amount]).to_d - (inv_data[:balance] || inv_data[:amount]).to_d,
          status: inv_data[:balance] == inv_data[:total] ? 'sent' : 'partial',
          contact_id: contact&.id,
          notes: "Imported from #{adapter.source_name}"
        )

        if invoice.save
          imported += 1
        else
          import_record.add_error('Invoice', inv_data[:invoice_number], invoice.errors.full_messages.join(', '))
          errors += 1
        end
      rescue => e
        import_record.add_error('Invoice', inv_data[:invoice_number], e.message)
        errors += 1
      end

      { imported: imported, skipped: skipped, errors: errors }
    end

    def generate_account_number(account_type)
      prefix = case account_type
               when 'asset' then '1'
               when 'liability' then '2'
               when 'equity' then '3'
               when 'revenue' then '4'
               when 'expense' then '5'
               else '9'
               end

      existing = @company.chart_of_accounts
        .where("account_number LIKE ?", "#{prefix}%")
        .pluck(:account_number)
        .map(&:to_i)
        .sort

      next_num = existing.any? ? existing.last + 10 : "#{prefix}000".to_i
      next_num.to_s
    end

    def find_or_skip_contact(name, email)
      return nil if name.blank? && email.blank?

      if email.present?
        @company.contacts.find_by(email: email)
      elsif name.present?
        parts = name.split(' ', 2)
        @company.contacts.find_by(first_name: parts[0], last_name: parts[1])
      end
    end

    def resolve_parent_relationships(adapter, _accounts_data)
      mappings = adapter.parent_mappings
      mappings.each do |child_ext_id, parent_ext_id|
        child = @company.chart_of_accounts.find_by(qbo_account_id: child_ext_id)
        parent = @company.chart_of_accounts.find_by(qbo_account_id: parent_ext_id)
        child.update_column(:parent_id, parent.id) if child && parent
      end
    end
  end
end
