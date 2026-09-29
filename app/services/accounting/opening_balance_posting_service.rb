# frozen_string_literal: true

module Accounting
  # Posts an account's opening balance as a real journal entry against
  # Opening Balance Equity.
  #
  # The opening balance typed on an account used to be added to that account
  # at report time with nothing on the other side, so the books were out by
  # exactly the opening balances (a $50k bank opening balance put the balance
  # sheet out by $50k). One entry per account, replaced whenever the amount
  # or date changes, keeps both sides in the ledger.
  class OpeningBalancePostingService
    MEMO_PREFIX = 'Opening balance'
    OBE_NAME    = 'Opening Balance Equity'

    def initialize(account)
      @account = account
      @company = account.company
    end

    # Returns the new entry, or nil when there is no opening balance. Raises
    # ActiveRecord::RecordInvalid if the entry can't be saved (for example
    # its date falls in a closed period), so callers can surface the reason.
    #
    # legacy_conversion: the balance was already counted in every report
    # (added at report time), so posting it into a now-closed period changes
    # no closed figures. Only the conversion script passes this.
    def sync!(legacy_conversion: false)
      ActiveRecord::Base.transaction do
        existing_entries.each(&:destroy!)

        amount = (@account.opening_balance || 0).to_d
        next nil if amount.zero?

        obe = opening_balance_equity_account
        own_debit = (@account.normal_balance == 'debit') == amount.positive?
        value = amount.abs

        @company.journal_entries.create!(
          allow_closed_period: legacy_conversion,
          entry_date: entry_date,
          memo: "#{MEMO_PREFIX} — #{@account.account_number} #{@account.name}",
          source_type: 'auto',
          source_entity: @account,
          journal_entry_lines_attributes: [
            { chart_of_account_id: @account.id, debit_amount: own_debit ? value : 0, credit_amount: own_debit ? 0 : value,
              memo: MEMO_PREFIX },
            { chart_of_account_id: obe.id, debit_amount: own_debit ? 0 : value, credit_amount: own_debit ? value : 0,
              memo: "#{MEMO_PREFIX} — #{@account.name}" }
          ]
        )
      end
    end

    # An opening balance with no date used to count on every report date, so
    # it is dated no later than the company's first ledger entry, keeping it
    # in reports run for earlier dates too.
    def entry_date
      return @account.opening_balance_date if @account.opening_balance_date

      first = @company.journal_entries.in_ledger.where.not(source_entity: @account).minimum(:entry_date)
      [first, Date.current].compact.min
    end

    def existing_entries
      @company.journal_entries.where(source_entity: @account, is_void: false)
              .where('memo LIKE ?', "#{MEMO_PREFIX}%")
    end

    def opening_balance_equity_account
      @company.chart_of_accounts.find_by(name: OBE_NAME) ||
        @company.chart_of_accounts.create!(
          account_number: free_equity_number,
          name: OBE_NAME,
          account_type: 'equity',
          sub_type: 'owners_equity',
          normal_balance: 'credit',
          description: 'Offsets opening balances entered on accounts. Clear it into owner\'s equity or retained earnings once opening balances are final.'
        )
    end

    private

    def free_equity_number
      taken = @company.chart_of_accounts.pluck(:account_number).to_set
      (3900..3999).map(&:to_s).find { |n| !taken.include?(n) } || "3900-#{SecureRandom.hex(2)}"
    end
  end
end
