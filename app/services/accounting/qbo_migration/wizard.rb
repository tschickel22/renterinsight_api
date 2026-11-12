# frozen_string_literal: true

module Accounting
  module QboMigration
    # The migration's working state and every step of the wizard except
    # suggesting (AccountSuggester), posting (Poster) and rollback (Rollback).
    #
    # State lives in import.import_config, string keyed, with money kept as
    # decimal strings so nothing drifts through floats:
    #   mode                       'migration'
    #   quickbooks_company_name
    #   trial_balance              { start_date, end_date, total_debit, total_credit,
    #                                rows: [{ qbo_account_id, name, debit, credit, balance }] }
    #                              balance is debit minus credit
    #   accounts                   [row] (see #account_row)
    #   banks                      [{ qbo_account_id, name, kind, match: { bank_account_id, closed,
    #                                 previous_feed_start_date } | { part_of: qbo_account_id } }]
    #                              part_of: an employee card (or any account) the bank reports inside
    #                              another one, e.g. five employee cards on one company card statement.
    #                              It has no bank account of its own: its balance goes to that card's
    #                              account and ties out on that card's statement (see #part_of_map)
    #   uncleared                  { qbo_account_id => { statement_balance, statement_source ('bank' | 'typed'),
    #                                bank_balance: { status, amount, current, lines_after, as_of, ... }, items: [...] } }
    #                              bank_balance is what the bank feed says the statement balance was
    #                              (see #fetch_bank_balances!)
    #   lists                      { customers: [...], vendors: [...] }
    #   list_choices               { 'customers' | 'vendors' => { qbo external_id => { action: 'link' | 'new',
    #                                type: 'contact' | 'lead' | 'vendor', id } } }, what a person picked over
    #                                ListMatcher's answer (see #update_list_choices!)
    #   open_invoices, customer_credits, open_bills, vendor_credits
    #   notes                      { suggest:, uncleared: } messages for the person
    #   quickbooks_sync_before     what the older QuickBooks sync held before this switch turned it off
    #                              (OldSync.turn_off!); posted keeps the same list for Rollback
    #   preview_viewed_at, posted, rolled_back_at
    class Wizard
      BANK_TYPES = { 'Bank' => 'bank', 'Credit Card' => 'credit_card' }.freeze
      UNCLEARED_KINDS = %w[check deposit other].freeze
      CREDIT_NORMAL = %w[liability equity revenue].freeze

      attr_reader :import, :company

      # Returns the company's draft migration, or starts one (fetching the
      # QuickBooks company as of the cutover date).
      #
      # trial: a trial switch (E101). QuickBooks stays the books; the dealer
      # looks around, then updates the trial or goes live from it.
      # from: the earlier switch this one replaces (a trial being updated or
      # taken live). Its account choices and bank matches are carried over,
      # so the second run is nearly done before it starts.
      def self.start!(company:, user:, cutover_date:, trial: false, from: nil)
        existing = company.accounting_imports.migrations.find_by(status: 'draft')
        return existing if existing

        check_cutover!(company, cutover_date)

        unless QboMigration.fixture_mode? || QboMigration.connection_for(company)
          raise Error, 'QuickBooks Online is not connected. Connect it under Integrations, then start the switch again.'
        end

        config = { 'mode' => 'migration', 'trial' => trial ? true : false }
        if from
          earlier = from.import_config || {}
          config['from_import_id'] = from.id
          # When the first trial was posted: trial activity is what DealerTide
          # posted from then on, settled by date when the dealer goes live.
          config['trial_started_at'] = earlier['trial_started_at'].presence ||
                                       (earlier['trial'] ? earlier.dig('posted', 'posted_at') : nil)
          config.merge!(carried_choices(company, earlier))
        end

        import = company.accounting_imports.create!(
          user: user, source_type: 'quickbooks_online', status: 'draft', cutover_date: cutover_date,
          started_at: Time.current, import_config: config
        )
        wizard = new(import)
        wizard.refresh!(date_changed: from.present?)
        wizard.start_carried_feeds! if from
        # The older QuickBooks record sync is off from the start (OldSync).
        before = OldSync.turn_off!(company)
        if before.any?
          wizard.config['quickbooks_sync_before'] = before
          wizard.save!
        end
        import
      rescue StandardError
        import&.destroy if import&.persisted? && import.import_config['accounts'].nil?
        raise
      end

      # The switch reads QuickBooks when it starts or the date changes, and
      # bank feeds skip everything up to the cutover. A cutover still to come
      # would read QuickBooks as it is today and lose whatever is entered
      # between now and then from both systems. So the cutover must be a day
      # that has already started: today at the latest, usually the last day
      # of a month already finished in QuickBooks.
      def self.check_cutover!(company, date)
        return unless date && date > company.today

        raise Error, "The cutover date can't be in the future. Pick a day that has already happened, usually the " \
                     'last day of a month you have finished in QuickBooks. To switch at the end of this month, ' \
                     'start the switch once the month is over.'
      end

      # Account choices and bank matches from an earlier switch, as the
      # starting rows of a new one. A choice that created an account becomes a
      # map to that account (it stays after a rollback, carrying the
      # QuickBooks id). Only confirmed choices carry; refresh! keeps them and
      # re-suggests the rest for the new date.
      def self.carried_choices(company, earlier)
        by_qbo = company.chart_of_accounts.where.not(qbo_account_id: [nil, '']).index_by { |a| a.qbo_account_id.to_s }
        live_ids = company.chart_of_accounts.pluck(:id).to_set
        accounts = Array(earlier['accounts']).filter_map do |row|
          choice = row['choice']
          next unless row['confirmed'] && choice.present?

          if choice['action'] == 'create'
            acct = by_qbo[row['qbo_account_id'].to_s]
            next unless acct

            choice = { 'action' => 'map', 'chart_of_account_id' => acct.id }
          elsif choice['action'] == 'map'
            next unless live_ids.include?(choice['chart_of_account_id'])
          end
          { 'qbo_account_id' => row['qbo_account_id'].to_s, 'choice' => choice, 'confirmed' => true,
            'suggestion' => nil }
        end

        bank_ids = company.bank_accounts.where(is_deleted: [false, nil]).pluck(:id).to_set
        banks = Array(earlier['banks']).filter_map do |bank|
          match = bank['match']
          next unless match.present?
          next if match['bank_account_id'] && !bank_ids.include?(match['bank_account_id'])

          { 'qbo_account_id' => bank['qbo_account_id'].to_s,
            'match' => match.slice('bank_account_id', 'closed', 'previous_feed_start_date', 'part_of') }
        end
        { 'accounts' => accounts, 'banks' => banks }
      end

      def self.d(value)
        return BigDecimal('0') if value.blank?

        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        BigDecimal('0')
      end

      def self.money(value)
        value.nil? ? nil : d(value).round(2).to_f
      end

      def initialize(import, adapter: nil)
        @import = import
        @company = import.company
        @adapter = adapter
      end

      def adapter
        @adapter ||= QboMigration.adapter_for(@company)
      end

      def config
        @config ||= (@import.import_config || {}).deep_dup
      end

      def save!
        @import.update!(import_config: config.deep_stringify_keys)
        @config = nil
      end

      def draft?
        @import.status == 'draft'
      end

      def ensure_draft!
        raise Error, 'This switch has already been posted. Roll it back to change it.' unless draft?
      end

      def cutover_date
        @import.cutover_date
      end

      # ── Fetch ───────────────────────────────────────────────────

      # Reads everything from QuickBooks as of the cutover date. Keeps the
      # person's choices; date_changed also drops unconfirmed suggestions and
      # the uncleared items, since both were worked out for the old date.
      def refresh!(date_changed: false)
        accounts = adapter.fetch_accounts
        tb = adapter.fetch_trial_balance(cutover_date)
        tb_by_id = tb[:rows].index_by { |r| r[:external_id] }

        old_rows = Array(config['accounts']).index_by { |r| r['qbo_account_id'] }
        rows = accounts.filter_map do |acct|
          balance = tb_by_id[acct[:external_id]]&.dig(:balance) || BigDecimal('0')
          next if !acct[:is_active] && balance.zero?

          account_row(acct, balance, old_rows[acct[:external_id]], date_changed)
        end
        known = rows.map { |r| r['qbo_account_id'] }.to_set
        tb[:rows].each do |tbr|
          next if known.include?(tbr[:external_id]) || tbr[:balance].zero?

          rows << account_row({ external_id: tbr[:external_id], name: tbr[:name], is_active: true,
                                account_type: tbr[:balance].positive? ? 'asset' : 'liability' },
                              tbr[:balance], old_rows[tbr[:external_id]], date_changed)
        end

        config['quickbooks_company_name'] = adapter.company_name
        config['trial_balance'] = {
          'start_date' => tb[:start_date].iso8601, 'end_date' => tb[:end_date].iso8601,
          'total_debit' => tb[:total_debit].to_s('F'), 'total_credit' => tb[:total_credit].to_s('F'),
          'rows' => tb[:rows].map do |r|
            { 'qbo_account_id' => r[:external_id], 'name' => r[:name], 'debit' => r[:debit].to_s('F'),
              'credit' => r[:credit].to_s('F'), 'balance' => r[:balance].to_s('F') }
          end
        }
        config['accounts'] = rows

        old_banks = Array(config['banks']).index_by { |b| b['qbo_account_id'] }
        config['banks'] = rows.select { |r| BANK_TYPES.key?(r['qbo_type']) }.map do |r|
          { 'qbo_account_id' => r['qbo_account_id'], 'name' => r['qbo_name'], 'kind' => BANK_TYPES[r['qbo_type']],
            'match' => old_banks.dig(r['qbo_account_id'], 'match') }
        end

        fetch_open_items!
        fetch_uncleared!(reset: date_changed || config['uncleared'].nil?)
        reapply_bank_matches!
        config.delete('preview_viewed_at')
        config['fetched_at'] = Time.current.iso8601
        save!
        self
      end

      # Matches carried from an earlier switch start their feeds the day after
      # this cutover, as a match made by hand here would.
      def start_carried_feeds!
        bank_rows.each do |bank|
          ba_id = bank.dig('match', 'bank_account_id')
          next unless ba_id

          @company.bank_accounts.find_by(id: ba_id)&.update_column(:feed_start_date, cutover_date + 1)
        end
      end

      def trial?
        config['trial'] ? true : false
      end

      # Going live from a trial: DealerTide activity since the trial started
      # that QuickBooks also holds. The cutover date decides which system owns
      # a transaction, so journal entries made since the trial started and
      # dated on or before the cutover were recorded in QuickBooks too (the
      # opening entry carries them) and are voided; feed lines on matched
      # banks dated on or before the cutover are excluded. Later activity is
      # DealerTide's and stays. Empty for a trial or a switch not from one.
      def settlement
        return { entries: [], bank_lines: [] } if trial? || config['trial_started_at'].blank?

        since = Time.zone.parse(config['trial_started_at'])
        # Never a switch's own entries (opening balances, and the reversal a
        # trial's rollback made of them: voiding that would put the trial's
        # balances back), and never any reversal, which only undoes another.
        reversals = @company.journal_entries.where.not(reversed_by_id: nil).select(:reversed_by_id)
        entries = @company.journal_entries.where(is_void: [false, nil])
                          .where('journal_entries.created_at >= ? AND entry_date <= ?', since, cutover_date)
                          .where('source_entity_type IS NULL OR source_entity_type <> ?', 'AccountingImport')
                          .where.not(id: reversals).order(:entry_date, :id).to_a
        # Feed lines up to the cutover that nobody booked yet (the opening
        # balances hold them), and lines booked by an entry voided here. A line
        # matched to an entry that stays (booked before the trial) is left
        # alone: excluding it would cut that entry off from reconciliation.
        # The film company's 50 older matched lines showed this (2026-11-11).
        bank_ids = matched_banks.map { |b| b.dig('match', 'bank_account_id') }
        voided = entries.map(&:id)
        lines = BankTransaction.where(bank_account_id: bank_ids).where('transaction_date <= ?', cutover_date)
                               .where.not(status: %w[excluded reconciled])
                               .where('status = ? OR matched_journal_entry_id IN (?)', 'unmatched', voided.presence || [0])
                               .order(:transaction_date, :id).to_a
        { entries: entries, bank_lines: lines }
      end

      def settlement_json
        s = settlement
        {
          entries: s[:entries].map do |je|
            { id: je.id, entry_number: je.entry_number, entry_date: je.entry_date&.iso8601, memo: je.memo,
              source_type: je.source_type, amount: self.class.money(je_total(je)) }
          end,
          bank_lines: s[:bank_lines].map do |bt|
            { id: bt.id, bank_account_id: bt.bank_account_id, date: bt.transaction_date&.iso8601,
              description: bt.try(:description), amount: self.class.money(bt.try(:amount)) }
          end
        }
      end

      # Matched banks whose feed is not connected: nothing comes in after the
      # cutover until it is, and a first pull reaches back about 90 days.
      def unconnected_banks
        matched_banks.filter_map do |bank|
          ba = company_bank_accounts.find { |a| a.id == bank.dig('match', 'bank_account_id') }
          next if ba.nil? || ba.feed_connected?

          { qbo_account_id: bank['qbo_account_id'], name: bank['name'], bank_account_id: ba.id,
            bank_account_name: bank_display_name(ba) }
        end
      end

      def change_cutover!(new_date)
        ensure_draft!
        return self if new_date == cutover_date

        self.class.check_cutover!(@company, new_date)

        @import.update!(cutover_date: new_date)
        Array(config['banks']).each do |bank|
          ba_id = bank.dig('match', 'bank_account_id')
          next unless ba_id

          @company.bank_accounts.find_by(id: ba_id)&.update_column(:feed_start_date, new_date + 1)
        end
        refresh!(date_changed: true)
      end

      # ── Accounts ────────────────────────────────────────────────

      def account_rows
        Array(config['accounts'])
      end

      def accounts_json
        account_rows.map { |row| public_row(row) }
      end

      def dealertide_accounts_json
        @company.chart_of_accounts.where(is_header: [false, nil]).ordered.map do |a|
          { id: a.id, number: a.account_number, name: a.name, account_type: a.account_type, sub_type: a.sub_type }
        end
      end

      def update_accounts!(entries, confirm_suggested: false)
        ensure_draft!
        errors = []
        rows = account_rows.index_by { |r| r['qbo_account_id'] }

        if confirm_suggested
          rows.each_value do |row|
            next if row['confirmed']

            sug = row['suggestion']
            next unless sug && (sug['source'] == 'exact' || sug['confidence'] == 'high')

            row['choice'] = choice_from(sug)
            row['confirmed'] = true
          end
        end

        Array(entries).each do |entry|
          entry = entry.to_h.deep_stringify_keys
          row = rows[entry['qbo_account_id'].to_s]
          unless row
            errors << "QuickBooks account #{entry['qbo_account_id']} is not part of this switch"
            next
          end

          if row['bank_match'] && entry.key?('action') && entry['action'].present? &&
             choice_from(entry) != row['choice']
            errors << "#{row['qbo_name']} follows its matched bank account. Change the match on the banks step."
            next
          end

          if entry.key?('action')
            case entry['action']
            when 'map'
              account = @company.chart_of_accounts.find_by(id: entry['chart_of_account_id'])
              if account.nil?
                errors << "#{row['qbo_name']}: choose a DealerTide account"
                next
              elsif account.is_header?
                errors << "#{row['qbo_name']}: #{account.account_number} #{account.name} is a header and cannot hold a balance"
                next
              end
              row['choice'] = { 'action' => 'map', 'chart_of_account_id' => account.id }
            when 'create'
              new_account, problem = clean_new_account(entry['new_account'], row, rows.values)
              if problem
                errors << "#{row['qbo_name']}: #{problem}"
                next
              end
              row['choice'] = { 'action' => 'create', 'new_account' => new_account }
            when nil, '', 'none'
              row['choice'] = nil
              row['confirmed'] = false
            else
              errors << "#{row['qbo_name']}: action must be map or create"
              next
            end
          end

          next unless entry.key?('confirmed')

          confirmed = ActiveModel::Type::Boolean.new.cast(entry['confirmed'])
          if confirmed && row['choice'].blank?
            errors << "#{row['qbo_name']}: choose where it goes before confirming"
            next
          end
          row['confirmed'] = confirmed || false
        end

        raise Error, errors.join('. ') if errors.any?

        config['accounts'] = rows.values
        config.delete('preview_viewed_at')
        save!
      end

      # ── Banks ───────────────────────────────────────────────────

      def bank_rows
        Array(config['banks'])
      end

      def banks_json
        rows = account_rows.index_by { |r| r['qbo_account_id'] }
        {
          qbo_bank_accounts: bank_rows.map do |b|
            match = b['match']
            {
              qbo_account_id: b['qbo_account_id'], name: b['name'], kind: b['kind'],
              balance_at_cutover: self.class.money(rows.dig(b['qbo_account_id'], 'balance_at_cutover')),
              match: match && { bank_account_id: match['bank_account_id'], closed: match['closed'] ? true : false }
                                .merge(match['part_of'].present? ? { part_of: match['part_of'] } : {}),
              qbo_parent_id: qbo_parent_bank_id(b),
              problems: bank_match_problems(b)
            }
          end,
          bank_accounts: company_bank_accounts.map do |ba|
            {
              id: ba.id, name: bank_display_name(ba),
              mask: ba.account_mask.presence || ba.display_last_four, kind: ba.account_type,
              feed_connected: ba.feed_connected?, feed_start_date: ba.feed_start_date&.iso8601
            }
          end
        }
      end

      def update_banks!(matches)
        ensure_draft!
        errors = []
        banks = bank_rows.index_by { |b| b['qbo_account_id'] }

        Array(matches).each do |m|
          m = m.to_h.deep_stringify_keys
          bank = banks[m['qbo_account_id'].to_s]
          unless bank
            errors << "QuickBooks account #{m['qbo_account_id']} is not a bank or card account in this switch"
            next
          end

          previous = bank['match'] || {}
          closed = ActiveModel::Type::Boolean.new.cast(m['closed']) || false
          ba_id = m['bank_account_id'].presence
          part_of = m['part_of'].presence&.to_s

          if part_of
            target = banks[part_of]
            if target.nil? || part_of == bank['qbo_account_id']
              errors << "#{bank['name']}: pick another QuickBooks bank or card to be part of"
              next
            elsif target['kind'] != bank['kind']
              errors << "#{bank['name']} can only be part of another #{bank['kind'] == 'credit_card' ? 'card' : 'bank account'}"
              next
            elsif target.dig('match', 'part_of') || banks.values.any? { |o| o.dig('match', 'part_of') == bank['qbo_account_id'] && o['qbo_account_id'] != part_of }
              errors << "#{bank['name']}: an account can be part of one that stands on its own, not part of a part"
              next
            end
            release_bank_account(previous, retire: true) if previous['bank_account_id']
            bank['match'] = { 'part_of' => part_of }
          elsif ba_id
            ba = company_bank_accounts.find { |a| a.id == ba_id.to_i }
            unless ba
              errors << "#{bank['name']}: that bank account was not found"
              next
            end
            taken = banks.values.find do |other|
              other['qbo_account_id'] != bank['qbo_account_id'] && other.dig('match', 'bank_account_id') == ba.id
            end
            if taken
              errors << "#{bank_display_name(ba)} is already matched to #{taken['name']}"
              next
            end

            prior_start = previous['bank_account_id'] == ba.id ? previous['previous_feed_start_date'] : ba.feed_start_date&.iso8601
            release_bank_account(previous) if previous['bank_account_id'] && previous['bank_account_id'] != ba.id
            ba.update_column(:feed_start_date, cutover_date + 1)
            bank['match'] = { 'bank_account_id' => ba.id, 'closed' => false, 'previous_feed_start_date' => prior_start }
          else
            release_bank_account(previous) if previous['bank_account_id']
            bank['match'] = closed ? { 'bank_account_id' => nil, 'closed' => true } : nil
          end
        end

        raise Error, errors.join('. ') if errors.any?

        config['banks'] = banks.values
        merge_part_of_items!
        reapply_bank_matches!
        config.delete('preview_viewed_at')
        save!
      end

      # { child qbo id => the qbo id it is part of }
      def part_of_map
        bank_rows.each_with_object({}) do |b, h|
          parent = b.dig('match', 'part_of')
          h[b['qbo_account_id']] = parent.to_s if parent.present?
        end
      end

      def parts_of(qbo_account_id)
        bank_rows.select { |b| b.dig('match', 'part_of').to_s == qbo_account_id.to_s }
      end

      # The QuickBooks bank or card this one sits under, when that is also a
      # bank or card here: QuickBooks' own parent, or the part of the name
      # before the last colon ("CORP CC 1849:Justin EHS 1740").
      def qbo_parent_bank_id(bank)
        rows = account_rows.index_by { |r| r['qbo_account_id'] }
        ids = bank_rows.map { |b| b['qbo_account_id'] }.to_set
        parent = rows.dig(bank['qbo_account_id'], 'qbo_parent_id')
        return parent if parent && ids.include?(parent) && parent != bank['qbo_account_id']

        name = rows.dig(bank['qbo_account_id'], 'qbo_name') || bank['name']
        prefix = name.to_s.rpartition(':').first
        return nil if prefix.blank?

        bank_rows.find { |b| b['qbo_account_id'] != bank['qbo_account_id'] && (rows.dig(b['qbo_account_id'], 'qbo_name') || b['name']) == prefix }&.dig('qbo_account_id')
      end

      # Uncleared checks and charges QuickBooks holds on an account that is
      # part of another move to that one's list, marked with where they came
      # from; when it stands on its own again they move back.
      def merge_part_of_items!
        config['uncleared'] ||= {}
        parts = part_of_map
        config['uncleared'].to_a.each do |id, state|
          next if parts.key?(id)

          back = Array(state['items']).select { |i| i['from_account'].present? && parts[i['from_account']] != id }
          next if back.empty?

          state['items'] = Array(state['items']) - back
          back.each do |item|
            dest = config['uncleared'][item['from_account']] ||= { 'statement_balance' => nil, 'items' => [] }
            dest['items'] = Array(dest['items']) + [item.except('from_account')]
          end
        end
        parts.each do |child, parent|
          child_state = config['uncleared'].delete(child)
          next if child_state.nil?

          dest = config['uncleared'][parent] ||= { 'statement_balance' => nil, 'items' => [] }
          dest['items'] = Array(dest['items']) + Array(child_state['items']).map { |i| i.merge('from_account' => child) }
        end
        # One standing on its own again needs its own statement balance.
        bank_rows.each do |b|
          next if parts.key?(b['qbo_account_id'])

          config['uncleared'][b['qbo_account_id']] ||= { 'statement_balance' => nil, 'items' => [] }
        end
      end

      # Gives every QuickBooks bank and card that has no match yet a
      # DealerTide bank account and matches it, so a dealer with nine of them
      # does not type nine in. Each is feed-only (no routing or account number
      # needed) and carries the last four digits from its QuickBooks name.
      # Connect a bank later attaches to an account of the same type and last
      # four (StripeBankFeedService#connect_fc_account!), so connecting fills
      # these in rather than adding a second copy. An existing unmatched
      # account of the same type and last four is matched instead of creating
      # another. No GL account is set: an unlinked bank takes the one its
      # QuickBooks account maps to when the switch posts.
      #
      # Returns { created:, matched_existing: } counts.
      def create_bank_accounts!
        ensure_draft!
        rows = account_rows.index_by { |r| r['qbo_account_id'] }
        taken = bank_rows.filter_map { |b| b.dig('match', 'bank_account_id') }
        # Loaded before anything is created: loaded lazily after the first
        # create, the list already held the new account and << added it twice
        # ("VisaVisa" in the staging click-through, 2026-11-11).
        company_bank_accounts
        matches = []
        created = 0
        existing = 0

        BankAccount.transaction do
          bank_rows.each do |bank|
            next if bank['match'].present?

            # An employee card under a company card in QuickBooks: the bank
            # sends one statement for the whole card, so it is part of it.
            parent = bank['kind'] == 'credit_card' ? qbo_parent_bank_id(bank) : nil
            parent_row = parent && bank_rows.find { |b| b['qbo_account_id'] == parent }
            if parent_row && parent_row['kind'] == 'credit_card' && parent_row.dig('match', 'part_of').blank?
              matches << { 'qbo_account_id' => bank['qbo_account_id'], 'part_of' => parent }
              next
            end

            type = bank_account_type(bank, rows[bank['qbo_account_id']])
            last4 = bank['name'].to_s[/(\d{4})\D*\z/, 1]
            ba = last4 && company_bank_accounts.find do |a|
              !taken.include?(a.id) && a.account_type == type &&
                (a.account_mask.to_s.end_with?(last4) || a.display_last_four == last4)
            end
            if ba
              existing += 1
            else
              ba = @company.bank_accounts.create!(
                bank_name: bank['name'].to_s.strip.presence || 'Bank account',
                account_type: type,
                account_purpose: BankAccount::ACCOUNT_PURPOSE_SYNC_ONLY,
                display_last_four: last4,
                account_mask: last4,
                created_by: 'quickbooks_switch'
              )
              company_bank_accounts << ba
              created += 1
            end
            taken << ba.id
            matches << { 'qbo_account_id' => bank['qbo_account_id'], 'bank_account_id' => ba.id }
          end

          update_banks!(matches) if matches.any?
        end

        { created: created, matched_existing: existing }
      end

      # Why a matched bank cannot carry its QuickBooks balance as matched. A
      # bank's balance is an asset and a card's is owed, so a card matched to
      # a checking account (or one whose GL is cash) would book what is owed
      # as money in the bank, and two accounts sharing a GL net into one
      # balance. Found in the 2026-10-03 browser test, where both happened
      # without a word.
      def bank_match_problems(bank)
        if (parent_id = bank.dig('match', 'part_of')).present?
          parent = bank_rows.find { |b| b['qbo_account_id'] == parent_id.to_s }
          return ['the account it is part of is no longer in this switch'] unless parent
          return ["#{parent['name']} is not matched to a bank or card here yet"] unless parent.dig('match', 'bank_account_id')

          return []
        end
        ba_id = bank.dig('match', 'bank_account_id')
        return [] unless ba_id

        ba = company_bank_accounts.find { |a| a.id == ba_id }
        return [] unless ba

        card = bank['kind'] == 'credit_card'
        name = bank_display_name(ba).presence || 'the matched account'
        problems = []
        if card && ba.account_type != 'credit_card'
          problems << "it is a credit card in QuickBooks but #{name} is a #{ba.account_type.to_s.tr('_', ' ')} account"
        elsif !card && ba.account_type == 'credit_card'
          problems << "it is a bank account in QuickBooks but #{name} is a credit card"
        end

        # A bank account with no GL account yet takes the one its QuickBooks
        # account is mapped to when the switch posts, so only a linked GL can
        # disagree with the kind.
        gl = ba.chart_of_account
        if gl
          wanted = card ? 'liability' : 'asset'
          if gl.account_type != wanted
            problems << "#{name} posts to #{gl.account_number} #{gl.name}, a#{'n' if gl.account_type.to_s.start_with?('a', 'e')} " \
                        "#{gl.account_type} account; a #{card ? 'card' : 'bank'} needs #{wanted == 'asset' ? 'an asset' : 'a liability'} account"
          elsif !card && gl.sub_type.present? && gl.sub_type != 'bank'
            # An asset is not enough: on the 2026-10-04 sandbox run a bank
            # linked to 1110 Customer Receivables put the Savings balance into
            # receivables.
            kind = gl.sub_type.tr('_', ' ')
            problems << "#{name} posts to #{gl.account_number} #{gl.name}, a#{'n' if kind.match?(/\A[aeiou]/)} #{kind} account, not a bank account. " \
                        'Link it to a bank account under Bank Accounts, or match a different bank'
          end
          shared = bank_rows.find do |other|
            next false if other['qbo_account_id'] == bank['qbo_account_id']

            other_ba = company_bank_accounts.find { |a| a.id == other.dig('match', 'bank_account_id') }
            other_ba && other_ba.chart_of_account_id == gl.id
          end
          problems << "#{name} posts to the same GL account as #{shared['name']}, so their balances would merge" if shared
        end
        problems
      end

      # ── Uncleared items ─────────────────────────────────────────

      def matched_banks
        bank_rows.select { |b| b.dig('match', 'bank_account_id').present? }
      end

      # difference = balance_at_cutover - statement_balance
      #              + sum(uncleared checks) - sum(uncleared deposits) - sum(other)
      # for a bank account, where balance and statement are what the bank
      # holds and 'other' amounts are signed as money into the account.
      # For a credit card the balances are what is owed, checks are charges
      # and deposits are payments, so the same tie reads
      #   owed - statement owed - charges + payments + other.
      # 0 means it ties. nil until a statement balance is entered.
      def uncleared_json
        { banks: matched_banks.map { |b| uncleared_bank_json(b) }, note: config.dig('notes', 'uncleared') }
      end

      def uncleared_bank_json(bank)
        state = config.dig('uncleared', bank['qbo_account_id']) || {}
        parts = parts_of(bank['qbo_account_id'])
        rows = account_rows.index_by { |r| r['qbo_account_id'] }
        balance = ([bank] + parts).sum(BigDecimal('0')) { |b| self.class.d(rows.dig(b['qbo_account_id'], 'balance_at_cutover')) }
        {
          qbo_account_id: bank['qbo_account_id'], name: bank['name'], kind: bank['kind'],
          bank_account_id: bank.dig('match', 'bank_account_id'),
          includes: parts.map { |b| b['name'] },
          balance_at_cutover: self.class.money(balance),
          statement_balance: self.class.money(state['statement_balance']),
          statement_from_bank: statement_from_bank?(state),
          bank_balance: bank_balance_json(state['bank_balance']),
          items: Array(state['items']).map do |i|
            { id: i['id'], date: i['date'], kind: i['kind'], payee: i['payee'], reference: i['reference'],
              amount: self.class.money(i['amount']), from_quickbooks: i['from_quickbooks'] ? true : false,
              from_account: i['from_account'].presence && bank_rows.find { |b| b['qbo_account_id'] == i['from_account'] }&.dig('name') }
          end,
          difference: self.class.money(uncleared_difference(bank))
        }
      end

      def uncleared_difference(bank)
        state = config.dig('uncleared', bank['qbo_account_id']) || {}
        return nil if state['statement_balance'].nil?

        # An account that is part of this one ties out on its statement too.
        ids = [bank['qbo_account_id']] + parts_of(bank['qbo_account_id']).map { |b| b['qbo_account_id'] }
        dp_book = account_rows.select { |r| ids.include?(r['qbo_account_id']) }.sum(BigDecimal('0')) { |r| self.class.d(r['tb_balance']) }
        dp_statement = statement_dp(bank, state['statement_balance'])
        flows = Array(state['items']).sum(BigDecimal('0')) { |i| item_flow(i) }
        dp_diff = dp_book - dp_statement - flows
        bank['kind'] == 'credit_card' ? -dp_diff : dp_diff
      end

      # The statement balance in debit-positive terms (a card's owed balance is
      # a credit).
      def statement_dp(bank, value)
        amount = self.class.d(value)
        bank['kind'] == 'credit_card' ? -amount : amount
      end

      # Money into the account, debit positive: deposits in, checks out.
      def item_flow(item)
        amount = self.class.d(item['amount'])
        case item['kind']
        when 'deposit' then amount.abs
        when 'check' then -amount.abs
        else amount
        end
      end

      def update_uncleared!(banks_param)
        ensure_draft!
        errors = []
        matched = matched_banks.index_by { |b| b['qbo_account_id'] }
        config['uncleared'] ||= {}

        Array(banks_param).each do |entry|
          entry = entry.to_h.deep_stringify_keys
          bank = matched[entry['qbo_account_id'].to_s]
          unless bank
            errors << "QuickBooks account #{entry['qbo_account_id']} is not a matched bank account"
            next
          end

          state = config['uncleared'][bank['qbo_account_id']] ||= { 'items' => [] }
          if entry.key?('statement_balance')
            raw = entry['statement_balance']
            if raw.blank?
              state['statement_balance'] = nil
              state.delete('statement_source')
            elsif numeric?(raw)
              state['statement_balance'] = self.class.d(raw).round(2).to_s('F')
              from_bank = state.dig('bank_balance', 'status') == 'ready' &&
                          self.class.d(state.dig('bank_balance', 'amount')) == self.class.d(state['statement_balance'])
              state['statement_source'] = from_bank ? 'bank' : 'typed'
            else
              errors << "#{bank['name']}: the statement balance must be a number"
            end
          end

          next unless entry.key?('items')

          old_items = Array(state['items']).index_by { |i| i['id'] }
          items = []
          Array(entry['items']).each_with_index do |item, idx|
            item = item.to_h.deep_stringify_keys
            label = "#{bank['name']}, item #{idx + 1}"
            date = parse_date(item['date'])
            if date.nil?
              errors << "#{label}: enter a date"
            elsif date > cutover_date
              errors << "#{label}: dated after the cutover, so it belongs in the bank feed"
            end
            errors << "#{label}: kind must be check, deposit or other" unless UNCLEARED_KINDS.include?(item['kind'])
            errors << "#{label}: the amount must be a number other than zero" unless numeric?(item['amount']) && self.class.d(item['amount']).nonzero?
            amount = self.class.d(item['amount'])
            amount = amount.abs unless item['kind'] == 'other'
            id = item['id'].presence || "u-#{SecureRandom.hex(4)}"
            items << {
              'id' => id, 'date' => date&.iso8601, 'kind' => item['kind'], 'payee' => item['payee'].presence,
              'reference' => item['reference'].presence, 'amount' => amount.round(2).to_s('F'),
              'from_quickbooks' => old_items.dig(id, 'from_quickbooks') || false,
              'qbo_txn_id' => old_items.dig(id, 'qbo_txn_id'),
              'from_account' => old_items.dig(id, 'from_account')
            }.compact
          end
          state['items'] = items
        end

        raise Error, errors.join('. ') if errors.any?

        config.delete('preview_viewed_at')
        save!
      end

      # ── Statement balances from the bank feed ───────────────────

      # Asks each matched bank with a connected feed for its balance at the
      # end of the cutover day (StripeBankFeedService#balance_on) and keeps
      # the answer on the bank's uncleared state. A blank statement balance,
      # or one filled from the bank earlier, takes the bank's figure; one the
      # person typed is never overwritten. Stripe answers 'pending' while it
      # fetches; the screen asks again until every bank is ready.
      def fetch_bank_balances!(service: nil)
        ensure_draft!
        config['uncleared'] ||= {}
        zone = ActiveSupport::TimeZone[@company.time_zone] || Time.zone
        accounts = @company.bank_accounts.where(id: matched_banks.map { |b| b.dig('match', 'bank_account_id') }).index_by(&:id)
        changed = false

        matched_banks.each do |bank|
          state = config['uncleared'][bank['qbo_account_id']] ||= { 'statement_balance' => nil, 'items' => [] }
          ba = accounts[bank.dig('match', 'bank_account_id').to_i]
          result =
            if ba.nil?
              { status: 'unavailable', reason: 'The matched bank account was not found' }
            elsif ba.stripe_fc_account_id.blank? || ba.stripe_fc_status != 'active'
              { status: 'not_connected' }
            else
              begin
                (service ||= StripeBankFeedService.new(@company)).balance_on(ba, cutover_date, zone: zone)
              rescue StandardError => e
                Rails.logger.warn("[QboMigration] bank balance for bank account #{ba.id}: #{e.message}")
                { status: 'unavailable', reason: 'Bank balances are not available right now' }
              end
            end
          state['bank_balance'] = bank_balance_state(bank, result)
          next unless result[:status] == 'ready'

          amount = state['bank_balance']['amount']
          fill = state['statement_balance'].nil? || state['statement_source'] == 'bank'
          next unless fill && state['statement_balance'] != amount

          state['statement_balance'] = amount
          state['statement_source'] = 'bank'
          changed = true
        end

        config.delete('preview_viewed_at') if changed
        save!
      end

      # Money in the statement's own terms: what the bank holds, or for a
      # card what is owed (Stripe signs a card's debt negative).
      def bank_balance_state(bank, result)
        out = { 'status' => result[:status].to_s, 'checked_at' => Time.current.iso8601 }
        out['reason'] = result[:reason] if result[:reason]
        return out unless result[:status] == 'ready'

        sign = bank['kind'] == 'credit_card' ? -1 : 1
        out.merge(
          'amount' => (result[:balance] * sign).round(2).to_s('F'),
          'current' => (result[:current] * sign).round(2).to_s('F'),
          'lines_after' => result[:lines_after],
          'as_of' => result[:as_of].iso8601,
          'old_date' => result[:old_date] ? true : false
        )
      end

      def bank_balance_json(bb)
        return nil if bb.blank?

        {
          status: bb['status'], reason: bb['reason'], amount: self.class.money(bb['amount']),
          current: self.class.money(bb['current']), lines_after: bb['lines_after'], as_of: bb['as_of'],
          old_date: bb['old_date'] ? true : false, checked_at: bb['checked_at']
        }
      end

      def statement_from_bank?(state)
        state['statement_source'] == 'bank' && state['statement_balance'].present? &&
          state.dig('bank_balance', 'status') == 'ready' &&
          self.class.d(state.dig('bank_balance', 'amount')) == self.class.d(state['statement_balance'])
      end

      # ── Customers and vendors ───────────────────────────────────

      def list_matcher
        @list_matcher ||= ListMatcher.new(@company, choices: config['list_choices'], open_counts: list_open_counts)
      end

      # Open invoices and customer credits per QuickBooks customer, open bills
      # and vendor credits per vendor. One with any can't be left out.
      def list_open_counts
        count = ->(*lists, key) { lists.flat_map { |l| Array(config[l]) }.group_by { |i| i[key].to_s }.transform_values(&:size) }
        { 'customers' => count.call('open_invoices', 'customer_credits', 'customer_external_id'),
          'vendors' => count.call('open_bills', 'vendor_credits', 'vendor_external_id') }
      end

      # Each QuickBooks customer or vendor with what the switch will do with it.
      def list_rows(kind)
        @list_rows ||= {}
        @list_rows[kind] ||= list_matcher.rows(kind, config.dig('lists', kind))
      end

      def list_counts
        ListMatcher::KINDS.index_with do |kind|
          rows = list_rows(kind)
          %w[link convert_lead new needs_choice skip].index_with { |st| rows.count { |r| r[:status] == st } }.symbolize_keys
        end.symbolize_keys
      end

      def lists_json
        { customers: list_rows('customers'), vendors: list_rows('vendors'), counts: list_counts,
          posted: !draft? }
      end

      # choices: [{ kind, external_id, action: 'link' | 'new' | 'skip' | 'auto', type, id }]. 'auto' forgets a
      # choice so matching decides again; 'skip' is Don't bring over, only for
      # one with nothing open. Without an external_id: 'skip_new' leaves out
      # every one that would be created and has nothing open, 'bring_all'
      # brings back every one left out.
      def update_list_choices!(choices)
        ensure_draft!
        saved = (config['list_choices'] ||= {})
        Array(choices).each do |c|
          kind = c['kind'].to_s
          raise Error, 'Unknown list' unless ListMatcher::KINDS.include?(kind)

          if c['external_id'].blank? && %w[skip_new bring_all].include?(c['action'].to_s)
            if c['action'].to_s == 'skip_new'
              list_rows(kind).each do |r|
                (saved[kind] ||= {})[r[:external_id]] = { 'action' => 'skip' } if r[:status] == 'new' && r[:open_items].zero?
              end
            else
              (saved[kind] || {}).delete_if { |_ext, ch| ch['action'] == 'skip' }
            end
            @list_matcher = nil
            @list_rows = nil
            next
          end

          ext = c['external_id'].to_s
          unless Array(config.dig('lists', kind)).any? { |q| q['external_id'].to_s == ext }
            raise Error, "QuickBooks #{kind == 'customers' ? 'customer' : 'vendor'} #{ext} is not in this switch"
          end

          case c['action'].to_s
          when 'auto'
            saved[kind]&.delete(ext)
          when 'skip'
            open = list_open_counts.dig(kind, ext).to_i
            if open.positive?
              raise Error, "#{kind == 'customers' ? 'This customer' : 'This vendor'} has #{open} open " \
                           "#{kind == 'customers' ? 'invoice or credit' : 'bill or credit'}#{open == 1 ? '' : 's'} in QuickBooks, so it has to come over"
            end
            (saved[kind] ||= {})[ext] = { 'action' => 'skip' }
          when 'new'
            (saved[kind] ||= {})[ext] = { 'action' => 'new' }
          when 'link'
            type = c['type'].to_s
            allowed = kind == 'customers' ? %w[contact lead] : %w[vendor]
            raise Error, 'That kind of record cannot be matched here' unless allowed.include?(type)
            raise Error, 'That record was not found' unless list_matcher.find_target(type, c['id'])

            (saved[kind] ||= {})[ext] = { 'action' => 'link', 'type' => type, 'id' => c['id'].to_i }
          else
            raise Error, 'Pick a record or Create new'
          end
        end
        @list_matcher = nil
        @list_rows = nil
        config.delete('preview_viewed_at')
        save!
      end

      # The older QuickBooks record sync (OldSync): what is on now, and what
      # this switch turned off when it started or posted.
      def old_quickbooks_sync
        OldSync.summary(@company).merge(
          turned_off: Array(config['quickbooks_sync_before']).map do |p|
            { type: p['type'], id: p['id'], name: p['name'], entities: Array(p['entities']), auto_sync: p['auto_sync'] ? true : false }
          end,
          locked: OldSync.lock(@company).present?
        )
      end

      # ── Preview ─────────────────────────────────────────────────

      # Every QuickBooks account with a balance lands in the entry, and the
      # entry's accounts net to exactly what QuickBooks holds for them.
      def carries_every_balance?(entry)
        with_balance = account_rows.reject { |r| self.class.d(r['tb_balance']).zero? }
        carried = entry[:rows].sum { |r| r[:qbo_names].size }
        qbo_net = with_balance.sum(BigDecimal('0')) { |r| self.class.d(r['tb_balance']) }
        entry_net = entry[:rows].sum(BigDecimal('0')) { |r| r[:debit] - r[:credit] }
        carried == with_balance.size && (qbo_net - entry_net).abs < BigDecimal('0.005')
      end

      def preview_json(mark_viewed: true)
        if mark_viewed && draft?
          config['preview_viewed_at'] = Time.current.iso8601
          save!
        end

        entry = OpeningEntryBuilder.new(self).build
        tb = config['trial_balance'] || {}
        inv = open_invoices_summary
        bills = open_bills_summary
        differences = []
        if inv[:difference].nonzero?
          differences << "Open invoices less customer credits total #{fmt(inv[:total])} but receivables in QuickBooks are " \
                         "#{fmt(inv[:ar_balance])} (difference #{fmt(inv[:difference])}). A payment applied in QuickBooks after the " \
                         'cutover to an earlier unapplied payment is the usual cause; run the A/R Aging report in QuickBooks as of the ' \
                         'cutover to find it.'
        end
        if inv[:unapplied_customer_credits].positive?
          differences << "#{fmt(inv[:unapplied_customer_credits])} of customer credits has no open invoice from the same " \
                         'customer to apply to. It comes over as credit memos, ready to apply to their next invoice.'
        end
        if bills[:difference].nonzero?
          differences << "Open bills less vendor credits total #{fmt(bills[:total])} but payables in QuickBooks are " \
                         "#{fmt(bills[:ap_balance])} (difference #{fmt(bills[:difference])})."
        end
        if entry[:plug].nonzero?
          differences << "The opening entry is out by #{fmt(entry[:plug].abs)}, so that amount " \
                         "#{entry[:plug].positive? ? 'is credited' : 'is debited'} to Opening Balance Equity. " \
                         'Check the QuickBooks trial balance before posting.'
        end
        if bills[:unapplied_vendor_credits].positive?
          differences << "#{fmt(bills[:unapplied_vendor_credits])} of vendor credits has no open bill from the same " \
                         'vendor to apply to. It stays in the opening entry; enter it as a vendor credit after posting.'
        end

        blocker_list = blocker_items(include_preview: false)
        blockers = blocker_list.map { |b| b[:message] }
        {
          trial_balance: entry[:rows].map do |r|
            { dealertide_account: r[:label], qbo_accounts: r[:qbo_names], debit: self.class.money(r[:debit]),
              credit: self.class.money(r[:credit]) }
          end,
          # Totals of the table, each DealerTide account netted. The posted
          # entry can have more lines (a matched bank is split into its
          # statement balance plus one line per uncleared item), and two
          # QuickBooks accounts sent to one DealerTide account net together,
          # so these can be lower than QuickBooks' totals with every balance
          # still carried; carries_every_balance says whether it is.
          totals: {
            debit: self.class.money(entry[:rows].sum(BigDecimal('0')) { |r| r[:debit] }),
            credit: self.class.money(entry[:rows].sum(BigDecimal('0')) { |r| r[:credit] }),
            qbo_debit: self.class.money(tb['total_debit']), qbo_credit: self.class.money(tb['total_credit']),
            entry_debit: self.class.money(entry[:total_debit]), entry_credit: self.class.money(entry[:total_credit]),
            carries_every_balance: carries_every_balance?(entry),
            combined_accounts: entry[:rows].count { |r| r[:qbo_names].size > 1 }
          },
          open_invoices: inv.slice(:count, :total, :ar_balance, :difference, :invoices_total, :customer_credits_total,
                                   :customer_credits_count, :unapplied_customer_credits)
                            .transform_values { |v| v.is_a?(Integer) ? v : self.class.money(v) },
          open_bills: {
            count: bills[:count], total: self.class.money(bills[:total]), ap_balance: self.class.money(bills[:ap_balance]),
            difference: self.class.money(bills[:difference]),
            bills_total: self.class.money(bills[:bills_total]), vendor_credits_total: self.class.money(bills[:vendor_credits_total])
          },
          # Amount credited to Opening Balance Equity; negative means debited.
          equity_plug: self.class.money(entry[:plug]),
          differences: differences,
          blockers: blockers,
          blocker_items: blocker_list,
          can_post: blockers.empty?,
          trial: trial?,
          settlement: settlement_json,
          unconnected_banks: unconnected_banks,
          quickbooks_sync: old_quickbooks_sync,
          lists: list_counts
        }
      end

      def open_invoices_summary
        list = Array(config['open_invoices'])
        credits = customer_credits
        invoices_total = list.sum(BigDecimal('0')) { |i| self.class.d(i['balance']) }
        credits_total = credits.sum(BigDecimal('0')) { |c| self.class.d(c['balance']) }
        total = invoices_total - credits_total
        ar = control_balance('Accounts Receivable')
        {
          count: list.size, total: total, ar_balance: ar, difference: total - ar, invoices_total: invoices_total,
          customer_credits_total: credits_total, customer_credits_count: credits.size,
          unapplied_customer_credits: unapplied_customer_credits
        }
      end

      # Open QuickBooks invoices already in DealerTide (an earlier QuickBooks
      # sync) whose balance there differs from QuickBooks. The switch skips an
      # invoice it finds by QuickBooks id, so these would leave receivables
      # short: on the 2026-10-04 sandbox run 40 such invoices held 243,579.36
      # in QuickBooks and were drafts, paid or zero in DealerTide.
      def conflicting_existing_invoices
        open = Array(config['open_invoices']).index_by { |i| i['external_id'].to_s }
        return [] if open.empty?

        @company.invoices.where(quickbooks_id: open.keys)
                .where('accounting_import_id IS NULL OR accounting_import_id <> ?', @import.id)
                .to_a.reject { |inv| inv.amount_due.to_d.round(2) == self.class.d(open[inv.quickbooks_id.to_s]['balance']).round(2) }
                .map { |inv| { invoice: inv, qbo_balance: self.class.d(open[inv.quickbooks_id.to_s]['balance']) } }
      end

      # Customer credits open at the cutover (credit memos, unapplied
      # payments). A draft started before they were read has none stored; they
      # are read once from QuickBooks then, with any customer they name.
      def customer_credits
        unless config.key?('customer_credits')
          return [] unless draft?

          credits = adapter.fetch_open_customer_credits(cutover_date)
          lists = (config['lists'] ||= {})
          known = Array(lists['customers']).map { |c| c['external_id'].to_s }.to_set
          missing = credits.map { |c| c[:customer_external_id] }.compact.uniq.reject { |id| known.include?(id.to_s) }
          lists['customers'] = Array(lists['customers']) + adapter.fetch_customers_by_id(missing).map { |c| jsonable(c) } if missing.any?
          config['customer_credits'] = credits.map { |c| jsonable(c) }
          save!
        end
        Array(config['customer_credits'])
      end

      # Customer credits with no open invoice from the same customer to absorb
      # them. They come over as credit memos.
      def unapplied_customer_credits
        open_by_customer = Array(config['open_invoices']).group_by { |i| i['customer_external_id'] }
        customer_credits.group_by { |c| c['customer_external_id'] }.sum(BigDecimal('0')) do |customer, credits|
          open = Array(open_by_customer[customer]).sum(BigDecimal('0')) { |i| self.class.d(i['balance']) }
          credit = credits.sum(BigDecimal('0')) { |c| self.class.d(c['balance']) }
          [credit - open, 0].max
        end
      end

      def open_bills_summary
        bills = Array(config['open_bills'])
        credits = Array(config['vendor_credits'])
        bills_total = bills.sum(BigDecimal('0')) { |b| self.class.d(b['balance']) }
        credits_total = credits.sum(BigDecimal('0')) { |c| self.class.d(c['balance']) }
        total = bills_total - credits_total
        ap = control_balance('Accounts Payable')
        {
          count: bills.size, total: total, ap_balance: ap, difference: total - ap, bills_total: bills_total,
          vendor_credits_total: credits_total, unapplied_vendor_credits: unapplied_vendor_credits
        }
      end

      # Vendor credits with no open bill from the same vendor to absorb them.
      def unapplied_vendor_credits
        bills_by_vendor = Array(config['open_bills']).group_by { |b| b['vendor_external_id'] }
        Array(config['vendor_credits']).group_by { |c| c['vendor_external_id'] }.sum(BigDecimal('0')) do |vendor, credits|
          open = Array(bills_by_vendor[vendor]).sum(BigDecimal('0')) { |b| self.class.d(b['balance']) }
          credit = credits.sum(BigDecimal('0')) { |c| self.class.d(c['balance']) }
          [credit - open, 0].max
        end
      end

      # The trial balance of every QuickBooks account of a control type, in
      # its normal direction (receivables positive, payables positive).
      def control_balance(qbo_type)
        account_rows.select { |r| r['qbo_type'] == qbo_type }.sum(BigDecimal('0')) { |r| self.class.d(r['balance_at_cutover']) }
      end

      # ── Migration object ────────────────────────────────────────

      def steps
        rows = account_rows
        with_balance = rows.select { |r| self.class.d(r['tb_balance']).nonzero? }
        banks = bank_rows
        lists = config['lists'] || {}
        matched_count = banks.count { |b| b['match'].present? }
        {
          connect: { done: QboMigration.fixture_mode? || QboMigration.connected?(@company) || !draft? },
          banks: { done: matched_count == banks.size && banks.none? { |b| bank_match_problems(b).any? },
                   matched: matched_count, total: banks.size,
                   problems: banks.sum { |b| bank_match_problems(b).size } },
          accounts: {
            done: with_balance.all? { |r| r['confirmed'] && r['choice'].present? },
            confirmed: rows.count { |r| r['confirmed'] }, total: rows.size,
            needs_attention: with_balance.count { |r| needs_attention?(r) }
          },
          lists: { done: config['lists'].present? && list_counts.values.sum { |c| c[:needs_choice] }.zero?,
                   customers: Array(lists['customers']).size, vendors: Array(lists['vendors']).size,
                   needs_choice: list_counts.values.sum { |c| c[:needs_choice] } },
          # Not done before the banks are decided: with nothing matched yet,
          # all? on an empty list read as "ties out".
          uncleared: { done: bank_rows.all? { |b| b['match'].present? } &&
                             matched_banks.all? { |b| uncleared_difference(b)&.zero? } },
          preview: { done: config['preview_viewed_at'].present? || !draft? }
        }
      end

      def needs_attention?(row)
        return true if type_mismatch(row)
        return false if row['confirmed']

        sug = row['suggestion']
        sug.nil? || (sug['source'] != 'exact' && sug['confidence'] != 'high')
      end

      def blockers(include_preview: true)
        blocker_items(include_preview: include_preview).map { |b| b[:message] }
      end

      # Each blocker with the wizard step where it is fixed (nil when it is
      # fixed outside the switch), so the preview can link straight to it:
      # "enter the bank statement balance" used to sit there with no way to
      # reach the box it meant.
      def blocker_items(include_preview: true)
        return [] unless draft?

        out = []
        steps = []
        # Tags the messages added since the last call with the step that fixes them.
        tag = ->(step) { steps.fill(step, steps.size...out.size) }
        # And with the QuickBooks account they are about, so the step can
        # scroll to that row and say what to fix there.
        ids = []
        about = ->(id) { ids.fill(id, ids.size...out.size) }
        rows = account_rows
        unmapped = rows.count { |r| self.class.d(r['tb_balance']).nonzero? && !(r['confirmed'] && r['choice'].present?) }
        out << "#{unmapped} #{unmapped == 1 ? 'account' : 'accounts'} with a balance #{unmapped == 1 ? 'is' : 'are'} not confirmed yet" if unmapped.positive?
        about.call(nil)

        tag.call('accounts')
        bank_rows.each do |b|
          out << "#{b['name']} is not matched to a bank account" if b['match'].blank?
          bank_match_problems(b).each { |problem| out << "#{b['name']}: #{problem}" }
          about.call(b['qbo_account_id'])
        end
        tag.call('banks')
        matched_banks.each do |b|
          diff = uncleared_difference(b)
          if diff.nil?
            out << "#{b['name']}: enter the bank statement balance at cutover"
          elsif diff.nonzero?
            out << "#{b['name']} does not tie to the bank statement (difference #{fmt(diff)})"
          end
          ba = @company.bank_accounts.find_by(id: b.dig('match', 'bank_account_id'))
          if ba && ba.bank_reconciliations.completed.where('statement_date >= ?', cutover_date).exists?
            out << "#{b['name']}: the matched bank account already has a reconciliation on or after the cutover date"
          end
          about.call(b['qbo_account_id'])
        end

        tag.call('uncleared')
        tb = config['trial_balance'] || {}
        tb_diff = self.class.d(tb['total_debit']) - self.class.d(tb['total_credit'])
        out << "The QuickBooks trial balance does not balance (out by #{fmt(tb_diff.abs)})" if tb_diff.nonzero?
        about.call(nil)

        tag.call(nil)
        rows.each do |r|
          choice = r['choice'] || {}
          next unless r['confirmed']

          if (problem = type_mismatch(r)) && self.class.d(r['tb_balance']).nonzero?
            out << "#{r['qbo_name']}: #{problem}"
          end

          if choice['action'] == 'map'
            acct = @company.chart_of_accounts.find_by(id: choice['chart_of_account_id'])
            out << "#{r['qbo_name']} is mapped to an account that no longer exists" if acct.nil?
            out << "#{r['qbo_name']} is mapped to a header account" if acct&.is_header?
          elsif choice['action'] == 'create'
            number = choice.dig('new_account', 'number')
            if @company.chart_of_accounts.exists?(account_number: number)
              out << "#{r['qbo_name']}: account number #{number} is already taken in DealerTide"
            end
          end
          about.call(r['qbo_account_id'])
        end

        tag.call('accounts')
        waiting = list_counts.values.sum { |c| c[:needs_choice] }
        if waiting.positive?
          out << "#{waiting} #{waiting == 1 ? 'customer or vendor has' : 'customers and vendors have'} more than one possible match. " \
                 'Pick which one, or Create new'
        end
        about.call(nil)

        tag.call('lists')
        closed = closed_period_on(cutover_date)
        out << "The cutover date is in a closed period (FY#{closed.fiscal_year} period #{closed.period_number})" if closed

        conflicts = conflicting_existing_invoices
        if conflicts.any?
          qbo = conflicts.sum(BigDecimal('0')) { |c| c[:qbo_balance] }
          here = conflicts.sum(BigDecimal('0')) { |c| c[:invoice].amount_due.to_d }
          sample = conflicts.first(5).map { |c| c[:invoice].invoice_number }.join(', ')
          out << "#{conflicts.size} open QuickBooks #{conflicts.size == 1 ? 'invoice is' : 'invoices are'} already in DealerTide " \
                 "from an earlier QuickBooks sync, owing #{fmt(here)} here against #{fmt(qbo)} in QuickBooks " \
                 "(#{sample}#{conflicts.size > 5 ? ', ...' : ''}). The switch would skip them and leave receivables short. " \
                 'Delete or void them in DealerTide first'
        end

        if (Array(config['open_invoices']).any? || Array(config['customer_credits']).any?) && default_location_id.nil?
          out << 'Add a location in DealerTide first: every invoice and credit memo needs one'
        end

        tag.call(nil)
        out << 'Open the preview before posting' if include_preview && config['preview_viewed_at'].blank?
        tag.call('preview')
        about.call(nil)
        out.each_index.map { |i| { message: out[i], step: steps[i], qbo_account_id: ids[i] } }
      end

      def migration_json
        {
          id: @import.id,
          status: @import.status,
          source_type: @import.source_type,
          cutover_date: cutover_date&.iso8601,
          quickbooks_company_name: config['quickbooks_company_name'],
          steps: steps,
          blockers: (items = blocker_items).map { |b| b[:message] },
          blocker_items: items,
          posted_at: config.dig('posted', 'posted_at'),
          rollback_available: @import.status == 'posted' && (refusal = Rollback.new(self).refusal).nil?,
          rollback_refusal: @import.status == 'posted' ? refusal : nil,
          trial: trial?,
          trial_started_at: config['trial_started_at'].presence || (trial? ? config.dig('posted', 'posted_at') : nil),
          from_import_id: config['from_import_id'],
          settled: config.dig('posted', 'settled')
        }
      end

      # ── Shared helpers ──────────────────────────────────────────

      # The account's own name, then the institution when it adds something.
      # Institution first read "StripeBank (ending 6789)" for both a checking
      # and a savings account (staging click-through, 2026-11-11).
      def bank_display_name(ba)
        own = ba.bank_name.to_s.strip
        inst = ba.institution_name.to_s.strip
        return inst if own.empty?
        return own if inst.empty? || own.downcase.include?(inst.downcase)

        "#{own} (#{inst})"
      end

      def je_total(entry)
        entry.journal_entry_lines.sum(&:debit_amount)
      end

      def company_bank_accounts
        @company_bank_accounts ||= @company.bank_accounts.where(is_deleted: [false, nil]).order(:id).to_a
      end

      # checking, savings or credit_card for a QuickBooks bank row.
      def bank_account_type(bank, row)
        return 'credit_card' if bank['kind'] == 'credit_card'

        sub = row ? row['qbo_sub_type'].to_s : ''
        sub.match?(/saving|moneymarket/i) || bank['name'].to_s.match?(/\bsavings?\b/i) ? 'savings' : 'checking'
      end

      def default_location_id
        loc = Current.location_id.presence && @company.locations.find_by(id: Current.location_id)
        (loc || @company.locations.order(:id).first)&.id
      end

      def closed_period_on(date)
        @company.fiscal_periods.where(status: %w[closed locked]).where('start_date <= ? AND end_date >= ?', date, date).first
      end

      def choice_from(source)
        source = source.to_h.deep_stringify_keys
        case source['action']
        when 'map' then { 'action' => 'map', 'chart_of_account_id' => source['chart_of_account_id']&.to_i }
        when 'create' then { 'action' => 'create', 'new_account' => source['new_account'] }
        end
      end

      def fmt(amount)
        ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', self.class.d(amount)))
      end

      private

      def account_row(acct, tb_balance, old, date_changed)
        dt_type = acct[:account_type] || 'expense'
        normal = CREDIT_NORMAL.include?(dt_type) ? -tb_balance : tb_balance
        keep_suggestion = old && (!date_changed || old['confirmed'])
        {
          'qbo_account_id' => acct[:external_id].to_s,
          'qbo_name' => acct[:fully_qualified_name].presence || acct[:name],
          'qbo_number' => acct[:account_number],
          'qbo_parent_id' => acct[:parent_external_id].presence&.to_s,
          'qbo_type' => acct[:qbo_type],
          'qbo_sub_type' => acct[:qbo_sub_type],
          'active' => acct[:is_active] != false,
          'balance_at_cutover' => normal.to_s('F'),
          'tb_balance' => tb_balance.to_s('F'),
          'dt_account_type' => dt_type,
          'dt_sub_type' => acct[:sub_type],
          'suggestion' => keep_suggestion ? old['suggestion'] : nil,
          'choice' => old&.dig('choice'),
          'confirmed' => old ? (old['confirmed'] || false) : false,
          'bank_match' => false
        }
      end

      # A balance sent to an account of another type lands on the wrong
      # statement: on the 2026-10-04 sandbox run, 36,642.84 of income went to
      # 1110 Customer Receivables. Nil when the types agree, or the row
      # follows a matched bank (bank_match_problems checks that GL).
      def type_mismatch(row)
        return nil if row['bank_match']

        want = row['dt_account_type']
        choice = row['choice'] || {}
        got, label =
          case choice['action']
          when 'map'
            acct = chart_by_id[choice['chart_of_account_id'].to_i]
            acct && [acct.account_type, "#{acct.account_number} #{acct.name}"]
          when 'create'
            [choice.dig('new_account', 'account_type'), "the new account #{choice.dig('new_account', 'number')} #{choice.dig('new_account', 'name')}"]
          end
        return nil if want.blank? || got.blank? || got == want

        "it is #{type_phrase(want)} in QuickBooks but goes to #{label}, #{type_phrase(got)}. Choose #{type_phrase(want)}"
      end

      def type_phrase(type)
        { 'asset' => 'an asset account', 'liability' => 'a liability account', 'equity' => 'an equity account',
          'revenue' => 'an income account', 'expense' => 'an expense account' }.fetch(type, "a #{type} account")
      end

      def chart_by_id
        @chart_by_id ||= @company.chart_of_accounts.index_by(&:id)
      end

      def public_row(row)
        {
          qbo_account_id: row['qbo_account_id'], qbo_name: row['qbo_name'], qbo_number: row['qbo_number'],
          qbo_type: row['qbo_type'], qbo_sub_type: row['qbo_sub_type'], active: row['active'],
          account_type: row['dt_account_type'],
          balance_at_cutover: self.class.money(row['balance_at_cutover']),
          suggestion: row['suggestion'], choice: row['choice'], confirmed: row['confirmed'] ? true : false,
          bank_match: row['bank_match'] ? true : false,
          part_of: row.dig('choice', 'action') == 'follow' ? bank_rows.find { |b| b['qbo_account_id'] == row.dig('choice', 'qbo_account_id') }&.dig('name') : nil,
          type_problem: type_mismatch(row)
        }
      end

      # A matched bank account's GL account is where that QuickBooks account's
      # balance goes, so the row is pinned to it and confirmed.
      def reapply_bank_matches!
        rows = account_rows.index_by { |r| r['qbo_account_id'] }
        was_pinned = rows.select { |_id, r| r['bank_match'] }.keys
        rows.each_value { |r| r['bank_match'] = false }
        bank_rows.each do |b|
          row = rows[b['qbo_account_id']]
          ba_id = b.dig('match', 'bank_account_id')
          next unless row && ba_id

          ba = company_bank_accounts.find { |a| a.id == ba_id }
          gl = ba&.chart_of_account
          next unless gl

          row['bank_match'] = true
          row['suggestion'] = { 'action' => 'map', 'chart_of_account_id' => gl.id, 'source' => 'exact', 'confidence' => 'high',
                                'reason' => "The GL account of the matched bank account #{bank_display_name(ba)}" }
          row['choice'] = { 'action' => 'map', 'chart_of_account_id' => gl.id }
          row['confirmed'] = true
        end
        # An account that is part of another goes wherever that one goes: the
        # same DealerTide account, decided by the matched bank's GL or on the
        # accounts step (Poster and OpeningEntryBuilder follow it).
        part_of_map.each do |child, parent|
          row = rows[child]
          next unless row && rows[parent]

          row['bank_match'] = true
          row['suggestion'] = nil
          row['choice'] = { 'action' => 'follow', 'qbo_account_id' => parent }
          row['confirmed'] = true
        end
        # A row pinned to a bank account's GL that is no longer matched (closed,
        # unmatched or matched elsewhere) drops the pin, so it does not keep
        # posting to the old bank's GL account. Found in the 2026-10-03
        # browser test: Wells Fargo, marked closed, still went to a card's GL.
        was_pinned.each do |id|
          row = rows[id]
          next if row.nil? || row['bank_match']

          row['suggestion'] = nil
          row['choice'] = nil
          row['confirmed'] = false
        end
        config['accounts'] = rows.values
      end

      # retire: the account is not needed any more (its QuickBooks account
      # became part of another). One the switch made itself, with no feed,
      # GL account or lines, is removed so it does not sit empty in Bank
      # Transactions.
      def release_bank_account(match, retire: false)
        ba = @company.bank_accounts.find_by(id: match['bank_account_id'])
        if retire && ba && ba.created_by == 'quickbooks_switch' && !ba.feed_connected? && ba.chart_of_account_id.nil? &&
           !ba.bank_transactions.exists?
          ba.soft_delete!
          @company_bank_accounts = nil
          return
        end
        return unless ba && ba.feed_start_date == cutover_date + 1

        prior = parse_date(match['previous_feed_start_date'])
        ba.update_column(:feed_start_date, prior)
        rows = account_rows.index_by { |r| r['qbo_account_id'] }
        bank = bank_rows.find { |b| b.dig('match', 'bank_account_id') == ba.id }
        row = bank && rows[bank['qbo_account_id']]
        # Dropping the pin entirely (not just unconfirming) so the row does not
        # keep the released bank's GL account as its choice.
        if row&.dig('bank_match')
          row['confirmed'] = false
          row['bank_match'] = false
          row['suggestion'] = nil
          row['choice'] = nil
        end
      end

      def fetch_open_items!
        invoices = adapter.fetch_open_invoices(cutover_date)
        customer_credits = adapter.fetch_open_customer_credits(cutover_date)
        bills = adapter.fetch_open_bills(cutover_date)
        credits = adapter.fetch_open_vendor_credits(cutover_date)

        customers = adapter.fetch_contacts
        missing = (invoices + customer_credits).map { |i| i[:customer_external_id] }.compact.uniq - customers.map { |c| c[:external_id] }
        customers += adapter.fetch_customers_by_id(missing) if missing.any?
        vendors = adapter.fetch_vendors
        missing = (bills + credits).map { |b| b[:vendor_external_id] }.compact.uniq - vendors.map { |v| v[:external_id] }
        vendors += adapter.fetch_vendors_by_id(missing) if missing.any?

        config['lists'] = { 'customers' => customers.map { |c| jsonable(c) }, 'vendors' => vendors.map { |v| jsonable(v) } }
        config['open_invoices'] = invoices.map { |i| jsonable(i) }
        config['customer_credits'] = customer_credits.map { |c| jsonable(c) }
        config['open_bills'] = bills.map { |b| jsonable(b) }
        config['vendor_credits'] = credits.map { |c| jsonable(c) }
      end

      def fetch_uncleared!(reset:)
        config['notes'] ||= {}
        old = config['uncleared'] || {}
        config['uncleared'] = {}
        suggestions = begin
          config['notes']['uncleared'] = 'Suggested from QuickBooks items not marked cleared on or before the cutover. ' \
                                         'Items that cleared after the cutover are not listed; add them by hand.'
          adapter.fetch_uncleared_items(cutover_date)
        rescue StandardError => e
          Rails.logger.warn("[QboMigration] uncleared items unavailable: #{e.message}")
          config['notes']['uncleared'] = 'QuickBooks did not return uncleared items. Enter them from your last bank statement.'
          {}
        end

        bank_rows.each do |bank|
          id = bank['qbo_account_id']
          if !reset && old[id]
            config['uncleared'][id] = old[id]
            next
          end
          # Already moved into the account it is part of.
          next if !reset && bank.dig('match', 'part_of').present?

          row = account_rows.find { |r| r['qbo_account_id'] == id } || {}
          names = [row['qbo_name'], bank['name']].compact.map(&:downcase)
          items = suggestions.select { |name, _| names.include?(name.to_s.downcase) || names.include?(name.to_s.split(':').last.to_s.downcase) }
                             .values.flatten
          config['uncleared'][id] = {
            'statement_balance' => nil,
            'items' => items.select { |i| parse_date(i[:date]).nil? || parse_date(i[:date]) <= cutover_date }.map do |i|
              { 'id' => "q-#{i[:external_id] || SecureRandom.hex(4)}", 'date' => i[:date], 'kind' => i[:kind],
                'payee' => i[:payee], 'reference' => i[:reference], 'amount' => i[:amount].to_d.round(2).to_s('F'),
                'from_quickbooks' => true, 'qbo_txn_id' => i[:external_id] }
            end
          }
        end
        merge_part_of_items!
      end

      def jsonable(hash)
        hash.transform_values do |v|
          case v
          when BigDecimal then v.to_s('F')
          when Date then v.iso8601
          else v
          end
        end.deep_stringify_keys
      end

      def clean_new_account(raw, row, all_rows)
        attrs = raw.to_h.deep_stringify_keys
        number = attrs['number'].to_s.strip
        name = attrs['name'].to_s.strip
        type = attrs['account_type'].presence || row['dt_account_type']
        sub_type = attrs['sub_type'].presence
        return [nil, 'a new account needs a number and a name'] if number.blank? || name.blank?
        return [nil, "#{type} is not an account type"] unless ChartOfAccount::TYPES.include?(type)
        if sub_type && !ChartOfAccount::SUB_TYPES_BY_TYPE.fetch(type, []).include?(sub_type)
          allowed = ChartOfAccount::SUB_TYPES_BY_TYPE.fetch(type, []).map { |t| t.tr('_', ' ') }.join(', ')
          return [nil, "#{sub_type.tr('_', ' ')} is not a detail type for #{type} accounts (choose #{allowed}, or none)"]
        end
        return [nil, "account number #{number} is already taken"] if @company.chart_of_accounts.exists?(account_number: number)

        clash = all_rows.find do |r|
          r['qbo_account_id'] != row['qbo_account_id'] && r.dig('choice', 'action') == 'create' &&
            r.dig('choice', 'new_account', 'number').to_s == number
        end
        return [nil, "account number #{number} is already planned for #{clash['qbo_name']}"] if clash

        parent_id = attrs['parent_id'].presence
        if parent_id
          parent = @company.chart_of_accounts.find_by(id: parent_id)
          return [nil, 'the parent account was not found'] unless parent

          parent_id = parent.id
        end
        [{ 'number' => number, 'name' => name, 'account_type' => type, 'sub_type' => sub_type, 'parent_id' => parent_id }, nil]
      end

      def numeric?(value)
        Float(value.to_s)
        true
      rescue ArgumentError, TypeError
        false
      end

      def parse_date(value)
        value.present? ? Date.parse(value.to_s) : nil
      rescue Date::Error
        nil
      end
    end
  end
end
