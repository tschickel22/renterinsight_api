# frozen_string_literal: true

module Accounting
  module QboMigration
    # Posts a migration in one transaction:
    #   1. creates the confirmed new accounts
    #   2. posts one opening entry dated the cutover date, from the trial
    #      balance through the mapping (equity plug only if it is out)
    #   3. links customers and vendors, keeping their QuickBooks ids
    #   4. saves open invoices and bills with their balance at cutover,
    #      WITHOUT posting them (the opening entry already holds AR and AP;
    #      accounting_import_id is the flag the auto-post callbacks respect)
    #   5. saves uncleared items as a completed opening reconciliation at the
    #      cutover, so the first real reconciliation starts from the statement
    #      balance with the uncleared checks and deposits waiting in it
    # Anything that fails rolls the whole thing back.
    class Poster
      def initialize(wizard, user)
        @wizard = wizard
        @import = wizard.import
        @company = wizard.company
        @user = user
        @created = { 'accounts' => [], 'contacts' => [], 'vendors' => [], 'bank_gl_links' => [] }
        @results = {}
      end

      def post!
        @wizard.ensure_draft!
        blockers = @wizard.blockers
        raise BlockedError.new(blockers) if blockers.any?

        ActiveRecord::Base.transaction do
          ids = create_accounts!
          link_bank_gl_accounts!(ids)
          entry = post_opening_entry!(ids)
          contacts = link_customers!
          vendors = link_vendors!
          save_invoices!(contacts)
          save_bills!(vendors, ids)
          save_reconciliations!(entry)

          @wizard.config['posted'] = @created.merge(
            'posted_at' => Time.current.iso8601, 'posted_by_id' => @user&.id,
            'journal_entry_id' => entry.id, 'results' => @results.deep_stringify_keys
          )
          @import.status = 'posted'
          @import.completed_at = Time.current
          @import.results = @results.deep_stringify_keys
          @import.total_imported = @results.values.sum { |v| v.is_a?(Hash) ? v[:created].to_i : 0 }
          @wizard.save!
        end
        @results
      end

      class BlockedError < Error
        attr_reader :blockers

        def initialize(blockers)
          @blockers = blockers
          super("This switch cannot post yet: #{blockers.join('; ')}")
        end
      end

      private

      def d(value) = Wizard.d(value)

      # { qbo_account_id => chart_of_account_id } for every mapped row.
      def create_accounts!
        ids = {}
        rows = @wizard.account_rows.select { |r| r['confirmed'] && r['choice'].present? }
        created = 0
        rows.each do |row|
          choice = row['choice']
          if choice['action'] == 'map'
            ids[row['qbo_account_id']] = @company.chart_of_accounts.find(choice['chart_of_account_id']).id
          elsif choice['action'] == 'create'
            na = choice['new_account']
            account = @company.chart_of_accounts.create!(
              account_number: na['number'], name: na['name'], account_type: na['account_type'],
              sub_type: na['sub_type'].presence, parent_id: na['parent_id'].presence &&
                                                             @company.chart_of_accounts.find(na['parent_id']).id,
              is_active: true, qbo_account_id: row['qbo_account_id'],
              description: "Created by the QuickBooks switch from #{row['qbo_name']}"
            )
            @created['accounts'] << account.id
            ids[row['qbo_account_id']] = account.id
            created += 1
          end
        end
        # Keep the QuickBooks id on mapped accounts that have none yet, so a
        # later sync or a second look can find them.
        rows.each do |row|
          next unless row.dig('choice', 'action') == 'map'

          acct = @company.chart_of_accounts.find(ids[row['qbo_account_id']])
          acct.update_column(:qbo_account_id, row['qbo_account_id']) if acct.qbo_account_id.blank?
        end
        @results[:accounts] = { created: created, mapped: rows.size - created }
        ids
      end

      # A matched bank account without a GL account gets the one its
      # QuickBooks account maps to, so reconciliation and the feed use it.
      def link_bank_gl_accounts!(ids)
        @wizard.matched_banks.each do |bank|
          ba = @company.bank_accounts.find(bank.dig('match', 'bank_account_id'))
          next if ba.chart_of_account_id.present?

          gl_id = ids[bank['qbo_account_id']]
          next unless gl_id

          ba.update_column(:chart_of_account_id, gl_id)
          @created['bank_gl_links'] << ba.id
        end
      end

      def post_opening_entry!(ids)
        accounts = @company.chart_of_accounts.where(id: ids.values.uniq).index_by(&:id)
        resolver = lambda do |row|
          id = ids[row['qbo_account_id']]
          acct = accounts[id]
          raise Error, "#{row['qbo_name']} has a balance but no DealerTide account" unless acct

          ["coa:#{acct.id}", "#{acct.account_number} #{acct.name}", acct.id]
        end
        built = OpeningEntryBuilder.new(@wizard, resolver: resolver).build
        obe = nil
        lines = built[:lines].map do |l|
          account_id = l[:chart_of_account_id]
          if l[:key] == OpeningEntryBuilder::OBE_KEY
            obe ||= opening_balance_equity_account
            account_id = obe.id
          end
          { chart_of_account_id: account_id, debit_amount: l[:debit_amount], credit_amount: l[:credit_amount],
            memo: l[:memo], _bank_qbo_id: l[:bank_qbo_id], _uncleared_item_id: l[:uncleared_item_id],
            _statement_line: l[:statement_line] }
        end
        raise Error, 'There is nothing to post: the trial balance at cutover is empty' if lines.size < 2

        entry = @company.journal_entries.build(
          entry_date: @wizard.cutover_date,
          memo: "Opening balances from QuickBooks Online as of #{@wizard.cutover_date.iso8601}",
          source_type: 'auto', source_entity: @import, posted_by: @user
        )
        @line_refs = []
        lines.each_with_index do |l, idx|
          line = entry.journal_entry_lines.build(l.except(:_bank_qbo_id, :_uncleared_item_id, :_statement_line).merge(position: idx))
          @line_refs << [line, l]
        end
        entry.save!
        @results[:opening_entry] = { created: 1, lines: lines.size, total: built[:total_debit].round(2).to_s('F'),
                                     equity_plug: built[:plug].round(2).to_s('F') }
        entry
      end

      def opening_balance_equity_account
        name = OpeningBalancePostingService::OBE_NAME
        @company.chart_of_accounts.find_by(name: name) || begin
          taken = @company.chart_of_accounts.pluck(:account_number).to_set
          number = (3900..3999).map(&:to_s).find { |n| !taken.include?(n) } || "3900-#{SecureRandom.hex(2)}"
          acct = @company.chart_of_accounts.create!(
            account_number: number, name: name, account_type: 'equity', sub_type: 'owners_equity', normal_balance: 'credit',
            description: 'Offsets opening balance differences. Clear it into owner\'s equity once the opening balances are final.'
          )
          @created['accounts'] << acct.id
          acct
        end
      end

      # { qbo customer id => contact }. Matched by QuickBooks id, then email,
      # then name; created otherwise. The QuickBooks id is kept either way.
      def link_customers!
        out = {}
        created = 0
        matched = 0
        location_id = @wizard.default_location_id
        Array(@wizard.config.dig('lists', 'customers')).each do |c|
          contact = @company.contacts.find_by(quickbooks_id: c['external_id'])
          contact ||= @company.contacts.where('LOWER(email) = ?', c['email'].downcase).first if c['email'].present?
          contact ||= find_contact_by_name(c)
          if contact
            contact.update_columns(quickbooks_id: c['external_id'], quickbooks_synced_at: Time.current) if contact.quickbooks_id.blank?
            matched += 1
          else
            first, last =
              if c['first_name'].present? then [c['first_name'], c['last_name']]
              elsif c['company_name'].present? then [c['company_name'], nil]
              else
                parts = c['name'].to_s.split(' ', 2)
                [parts.first.presence || 'Customer', parts.second]
              end
            contact = @company.contacts.create!(
              first_name: first, last_name: last, email: valid_email(c['email']), phone: valid_phone(c['phone']),
              company_name: c['company_name'], street: c['street'], city: c['city'], state: c['state'], zip: c['zip'],
              location_id: location_id, quickbooks_id: c['external_id'], quickbooks_synced_at: Time.current
            )
            @created['contacts'] << contact.id
            created += 1
          end
          out[c['external_id'].to_s] = contact
        end
        @results[:customers] = { created: created, matched: matched }
        out
      end

      def find_contact_by_name(c)
        if c['first_name'].present?
          @company.contacts.where('LOWER(first_name) = ? AND LOWER(COALESCE(last_name, \'\')) = ?',
                                  c['first_name'].downcase, c['last_name'].to_s.downcase).first
        elsif c['company_name'].present?
          @company.contacts.where('LOWER(company_name) = ?', c['company_name'].downcase).first
        end
      end

      def link_vendors!
        out = {}
        created = 0
        matched = 0
        vendors = @company.vendors.where(is_deleted: [false, nil])
        Array(@wizard.config.dig('lists', 'vendors')).each do |v|
          vendor = vendors.find_by(quickbooks_id: v['external_id']) || vendors.find_by(qb_vendor_id: v['external_id'])
          vendor ||= vendors.where('LOWER(email) = ?', v['email'].downcase).first if v['email'].present?
          vendor ||= vendors.where('LOWER(name) = ?', v['name'].to_s.downcase).first
          if vendor
            vendor.update_columns(quickbooks_id: v['external_id'], quickbooks_synced_at: Time.current) if vendor.quickbooks_id.blank?
            matched += 1
          else
            vendor = @company.vendors.create!(
              name: v['name'].presence || v['company_name'].presence || "QuickBooks vendor #{v['external_id']}",
              email: valid_email(v['email']), phone: valid_phone(v['phone'])&.first(20), address_line1: v['street'],
              city: v['city'], state: v['state'], zip_code: v['zip'], account_number: v['account_number'],
              vendor_type: 'supplier', status: v['active'] == false ? 'inactive' : 'active',
              quickbooks_id: v['external_id'], quickbooks_synced_at: Time.current, created_by_id: @user&.id
            )
            @created['vendors'] << vendor.id
            created += 1
          end
          out[v['external_id'].to_s] = vendor
        end
        @results[:vendors] = { created: created, matched: matched }
        out
      end

      def save_invoices!(contacts)
        created = 0
        skipped = 0
        location_id = @wizard.default_location_id
        Array(@wizard.config['open_invoices']).each do |inv|
          if @company.invoices.exists?(quickbooks_id: inv['external_id'])
            skipped += 1
            next
          end

          balance = d(inv['balance']).round(2)
          doc = inv['invoice_number'].presence || "QB-#{inv['external_id']}"
          number = @company.invoices.exists?(invoice_number: doc) ? "QB-#{doc}" : doc
          contact = contacts[inv['customer_external_id'].to_s]
          date = inv['date'].present? ? Date.parse(inv['date']) : @wizard.cutover_date
          invoice = @company.invoices.build(
            invoice_number: number, invoice_date: date, due_date: inv['due_date'].presence && Date.parse(inv['due_date']),
            status: 'sent', sent_at: date.to_time, contact_id: contact&.id, location_id: location_id,
            billing_category: 'customer', quickbooks_id: inv['external_id'], quickbooks_synced_at: Time.current,
            accounting_import_id: @import.id, tax_rate: 0,
            notes: "Carried over from QuickBooks Online invoice #{doc}. Original total #{@wizard.fmt(inv['total'])}, " \
                   "open balance at #{@wizard.cutover_date.iso8601} #{@wizard.fmt(balance)}."
          )
          invoice.invoice_items.build(
            description: "Open balance from QuickBooks invoice #{doc}", quantity: 1, rate: balance,
            item_type: 'custom', taxable: false, skip_tax: true
          )
          invoice.save!
          created += 1
        end
        @results[:open_invoices] = { created: created, skipped: skipped }
      end

      # Vendor credits come off the same vendor's open bills, oldest first.
      # What no bill absorbs is reported (it stays in AP through the opening
      # entry and is entered by hand as a vendor credit).
      def save_bills!(vendors, ids)
        ap_row = @wizard.account_rows.find { |r| r['qbo_type'] == 'Accounts Payable' && ids[r['qbo_account_id']] }
        ap_id = ap_row && ids[ap_row['qbo_account_id']]
        settings = AccountingSettings.find_by(company_id: @company.id)
        ap_id ||= settings&.default_ap_account_id ||
                  @company.chart_of_accounts.find_by(sub_type: 'accounts_payable', is_active: true)&.id

        bills = Array(@wizard.config['open_bills']).sort_by { |b| [b['date'].to_s, b['external_id'].to_s] }
                                                   .map { |b| b.merge('carry' => d(b['balance']).round(2)) }
        unapplied = BigDecimal('0')
        Array(@wizard.config['vendor_credits']).each do |vc|
          left = d(vc['balance']).round(2)
          bills.select { |b| b['vendor_external_id'] == vc['vendor_external_id'] }.each do |b|
            break if left.zero?

            take = [left, b['carry']].min
            b['carry'] -= take
            (b['credits'] ||= []) << "#{vc['doc_number'] || vc['external_id']} #{@wizard.fmt(take)}"
            left -= take
          end
          unapplied += left
        end

        created = 0
        skipped = 0
        bills.each do |b|
          if b['carry'] <= 0 || @company.bills.exists?(quickbooks_id: b['external_id'])
            skipped += 1
            next
          end
          raise Error, 'No accounts payable account to carry open bills against' unless ap_id

          vendor = vendors[b['vendor_external_id'].to_s]
          line_account = ids[b['expense_account_external_id'].to_s] || ap_id
          doc = b['doc_number'].presence || b['external_id']
          memo = +"Open balance carried over from QuickBooks bill #{doc}"
          memo << " (vendor credits applied: #{b['credits'].join(', ')})" if b['credits'].present?
          bill = @company.bills.build(
            vendor_id: vendor&.id, vendor_name: vendor&.name || b['vendor_name'],
            bill_date: b['date'].present? ? Date.parse(b['date']) : @wizard.cutover_date,
            due_date: b['due_date'].presence && Date.parse(b['due_date']), status: 'pending',
            reference_number: doc, memo: memo, ap_account_id: ap_id, tax_amount: 0, created_by_id: @user&.id,
            quickbooks_id: b['external_id'], accounting_import_id: @import.id
          )
          bill.bill_line_items.build(chart_of_account_id: line_account, amount: b['carry'],
                                     description: "Open balance from QuickBooks bill #{doc}")
          bill.save!
          created += 1
        end
        @results[:open_bills] = { created: created, skipped: skipped, unapplied_vendor_credits: unapplied.to_s('F') }
      end

      def save_reconciliations!(_entry)
        created = 0
        uncleared_count = 0
        @wizard.matched_banks.each do |bank|
          refs = @line_refs.select { |(_line, meta)| meta[:_bank_qbo_id] == bank['qbo_account_id'] }
          ba = @company.bank_accounts.find(bank.dig('match', 'bank_account_id'))
          statement = @wizard.statement_dp(bank, @wizard.config.dig('uncleared', bank['qbo_account_id'], 'statement_balance'))

          rec = @company.bank_reconciliations.create!(
            bank_account: ba, statement_date: @wizard.cutover_date, statement_ending_balance: statement,
            beginning_balance: 0, status: 'in_progress', accounting_import_id: @import.id,
            notes: 'Opening reconciliation from the QuickBooks switch. Uncleared checks and deposits at cutover carry into the next reconciliation.'
          )
          refs.each do |(line, meta)|
            rec.bank_reconciliation_items.create!(journal_entry_line: line, amount: line.net_amount,
                                                  cleared: meta[:_statement_line] ? true : false)
            uncleared_count += 1 unless meta[:_statement_line]
          end
          raise Error, "#{bank['name']} does not tie at cutover" unless rec.complete!(@user)

          created += 1
        end
        @results[:uncleared_items] = { created: uncleared_count, reconciliations: created }
      end

      def valid_email(email)
        email.present? && email.match?(URI::MailTo::EMAIL_REGEXP) ? email : nil
      end

      def valid_phone(phone)
        phone.present? && phone.match?(/\A[\d\s\-\(\)\+\.]+\z/) ? phone : nil
      end
    end
  end
end
