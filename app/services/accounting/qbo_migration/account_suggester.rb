# frozen_string_literal: true

require 'net/http'

module Accounting
  module QboMigration
    # Suggests where each QuickBooks account goes in DealerTide's chart.
    #
    # Deterministic first, without AI: same account number and the same
    # account type, and the receivables and payables control accounts (they
    # must land on the accounts the invoice and bill ledgers post to). Then
    # one batched Claude call for every row still without a suggestion.
    #
    # A confirmed row is never touched. If the AI call fails, the rows stay
    # unsuggested with a note and the wizard carries on by hand.
    class AccountSuggester
      API_URL = 'https://api.anthropic.com/v1/messages'
      CONFIDENCES = %w[high medium low].freeze

      SYSTEM_PROMPT = <<~PROMPT
        You map a manufactured housing or RV dealer's QuickBooks Online chart of accounts onto their DealerTide chart of accounts, for a switch to DealerTide's accounting.

        For each QuickBooks account you are given, decide one of:
        - "map": the balance belongs in an existing DealerTide account. Give its id from the DealerTide chart.
        - "create": no DealerTide account fits. Propose a new account: number, name, account_type and sub_type.

        Rules:
        - Map only to an account of the same account_type (asset, liability, equity, revenue, expense). A floor plan payable is a liability; inventory is an asset; cost of homes sold is an expense.
        - Prefer mapping when an existing account serves the same purpose, even if the name differs (for example "Floor Plan Payable - Triad" to a floor plan liability). Keep separate lenders, banks and cards in separate accounts rather than merging them.
        - Never map two different bank or credit card accounts to one account.
        - For "create", pick a number not already used in the DealerTide chart, following its numbering ranges, and use one of these sub types: %<sub_types>s.
        - reason: one short plain sentence a bookkeeper can check. No dashes.
        - confidence: "high" when the match is plain, "medium" when it is a judgment call, "low" when you are unsure.

        Answer with JSON only, no prose, in exactly this shape:
        {"suggestions":[{"qbo_account_id":"35","action":"map","chart_of_account_id":77,"reason":"...","confidence":"high"},{"qbo_account_id":"40","action":"create","new_account":{"number":"6510","name":"...","account_type":"expense","sub_type":"operating_expense"},"reason":"...","confidence":"medium"}]}
      PROMPT

      def initialize(wizard)
        @wizard = wizard
        @company = wizard.company
      end

      # Returns the wizard's rows after suggesting. Saves the state.
      def run!
        @wizard.ensure_draft!
        chart = @company.chart_of_accounts.where(is_header: [false, nil]).ordered.to_a
        rows = @wizard.account_rows
        pending = rows.reject { |r| r['confirmed'] }

        # Every unconfirmed row is suggested afresh: an old exact match that the
        # rule no longer makes must not survive and skip the AI. Remember what
        # the old suggestion would have chosen, so a choice that merely
        # followed it can follow the new one (a choice the person picked stays).
        followed = pending.to_h do |row|
          [row['qbo_account_id'], row['choice'].present? && row['choice'] == @wizard.choice_from(row['suggestion'])]
        end
        pending.each { |row| row['suggestion'] = deterministic(row, chart) }

        for_ai = pending.reject { |r| r.dig('suggestion', 'source') == 'exact' }
        notes = (@wizard.config['notes'] ||= {})
        notes.delete('suggest')
        if for_ai.any?
          begin
            ai = ask_claude(for_ai, chart)
            for_ai.each do |row|
              sug = clean_ai(ai[row['qbo_account_id']], row, chart, rows)
              row['suggestion'] = sug
            end
            missing = for_ai.count { |r| r['suggestion'].nil? }
            notes['suggest'] = "#{missing} #{missing == 1 ? 'account has' : 'accounts have'} no suggestion. Choose them by hand." if missing.positive?
          rescue StandardError => e
            Rails.logger.warn("[QboMigration] account suggestions failed: #{e.class}: #{e.message}")
            for_ai.each { |row| row['suggestion'] = nil }
            notes['suggest'] = 'Suggestions are not available right now, so the remaining accounts need choosing by hand. ' \
                               'You can also try Suggest again later.'
          end
        end

        # A suggestion fills an empty choice, or one that only followed the
        # previous suggestion; never one the person made.
        pending.each do |row|
          next unless row['choice'].blank? || followed[row['qbo_account_id']]

          row['choice'] = row['suggestion'] ? @wizard.choice_from(row['suggestion']) : nil
        end

        @wizard.config['accounts'] = rows
        @wizard.config.delete('preview_viewed_at')
        @wizard.save!
        @wizard.account_rows
      end

      # Kept separate so specs stub the network and nothing else.
      def request_claude(system, user_text)
        api_key = ENV['ANTHROPIC_API_KEY'].presence || Rails.application.credentials.dig(:anthropic, :api_key)
        raise Error, 'Anthropic API key not configured' if api_key.blank?

        uri = URI(API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 180
        http.open_timeout = 15
        request = Net::HTTP::Post.new(uri, 'content-type' => 'application/json', 'x-api-key' => api_key,
                                           'anthropic-version' => '2023-06-01')
        request.body = {
          model: AiModel.for(:classification), max_tokens: 16_000, temperature: 0, system: system,
          messages: [{ role: 'user', content: user_text }]
        }.to_json
        response = http.request(request)
        raise Error, "Claude returned #{response.code}" unless response.code.to_i == 200

        Array(JSON.parse(response.body)['content']).select { |c| c['type'] == 'text' }.map { |c| c['text'] }.join
      end

      private

      def deterministic(row, chart)
        type = row['dt_account_type']
        settings = AccountingSettings.find_by(company_id: @company.id)

        if row['qbo_type'] == 'Accounts Receivable'
          ar = settings&.default_ar_account || chart.find { |a| a.sub_type == 'accounts_receivable' && a.is_active }
          return exact(ar, 'Receivables control account: open invoices post against it') if ar
        end
        if row['qbo_type'] == 'Accounts Payable'
          ap = settings&.default_ap_account || chart.find { |a| a.sub_type == 'accounts_payable' && a.is_active }
          return exact(ap, 'Payables control account: open bills post against it') if ap
        end

        number = row['qbo_number'].to_s.strip
        return nil if number.blank?

        # Two charts can share a number by coincidence (QuickBooks 1010
        # "Wells Fargo Payroll" against DealerTide 1010 "Operating Checking"),
        # so the names must also agree on what the account is for. Words every
        # chart uses (inventory, expense, payable) do not count: in the
        # 2026-10-03 browser test they paired 1250 "Parts and Supplies
        # Inventory" with "Land / Lot Inventory" and 6600 "Depreciation
        # Expense" with "Vehicle Expense - Fuel". The rest goes to the AI.
        match = chart.find do |a|
          a.account_number == number && a.account_type == type && names_agree?(a.name, row['qbo_name'])
        end
        match && exact(match, 'Same account number, type and name')
      end

      STOP_WORDS = %w[and of the a an for to account accounts acct].freeze
      GENERIC_WORDS = %w[inventory expense income revenue payable receivable cost sale sold home other general misc
                         miscellaneous asset liability equity fee charge].freeze

      # At least half of the distinctive words of the shorter name appear in
      # the other. A name with no distinctive words never matches here.
      def names_agree?(left, right)
        a = name_words(left) - GENERIC_WORDS
        b = name_words(right) - GENERIC_WORDS
        return false if a.empty? || b.empty?

        shared = (a & b).size
        shared.positive? && shared * 2 >= [a.size, b.size].min
      end

      def name_words(name)
        name.to_s.downcase.scan(/[a-z]+/).map { |w| w.sub(/s\z/, '') }.reject { |w| w.size < 3 || STOP_WORDS.include?(w) }
      end

      def exact(account, reason)
        { 'action' => 'map', 'chart_of_account_id' => account.id, 'reason' => reason, 'source' => 'exact',
          'confidence' => 'high' }
      end

      def ask_claude(rows, chart)
        system = format(SYSTEM_PROMPT, sub_types: ChartOfAccount::SUB_TYPES.join(', '))
        payload = {
          dealer_industry: @company.try(:industry),
          dealertide_chart: chart.map do |a|
            { id: a.id, number: a.account_number, name: a.name, account_type: a.account_type, sub_type: a.sub_type,
              active: a.is_active }
          end,
          quickbooks_accounts: rows.map do |r|
            { qbo_account_id: r['qbo_account_id'], number: r['qbo_number'], name: r['qbo_name'], qbo_type: r['qbo_type'],
              qbo_sub_type: r['qbo_sub_type'], account_type: r['dt_account_type'], active: r['active'],
              balance_at_cutover: Wizard.money(r['balance_at_cutover']) }
          end
        }
        text = request_claude(system, "Suggest a DealerTide account for each QuickBooks account. JSON only.\n\n#{payload.to_json}")
        json = parse_json(text)
        Array(json['suggestions']).each_with_object({}) do |s, h|
          h[s['qbo_account_id'].to_s] = s if s.is_a?(Hash)
        end
      end

      def parse_json(text)
        JSON.parse(text)
      rescue JSON::ParserError
        start = text.index('{')
        stop = text.rindex('}')
        raise Error, 'Claude did not answer with JSON' unless start && stop

        JSON.parse(text[start..stop])
      end

      # Only suggestions that could actually post survive: a real, non header
      # account of the same type, or a new account with a valid type and a
      # free number.
      def clean_ai(sug, row, chart, rows)
        return nil unless sug

        confidence = CONFIDENCES.include?(sug['confidence']) ? sug['confidence'] : 'low'
        reason = sug['reason'].to_s.gsub(/\s*[\u2013\u2014]\s*/, ', ').squish.first(240)
        base = { 'reason' => reason, 'source' => 'ai', 'confidence' => confidence }

        case sug['action']
        when 'map'
          acct = chart.find { |a| a.id == sug['chart_of_account_id'].to_i }
          return nil unless acct && acct.account_type == row['dt_account_type']

          base.merge('action' => 'map', 'chart_of_account_id' => acct.id)
        when 'create'
          na = sug['new_account'].to_h
          type = ChartOfAccount::TYPES.include?(na['account_type']) ? na['account_type'] : row['dt_account_type']
          sub_type = ChartOfAccount::SUB_TYPES.include?(na['sub_type']) ? na['sub_type'] : row['dt_sub_type']
          name = na['name'].to_s.gsub(/\s*[\u2013\u2014]\s*/, ' ').squish.presence || row['qbo_name']
          number = free_number(na['number'].to_s.strip.presence || row['qbo_number'], type, chart, rows, row)
          base.merge('action' => 'create',
                     'new_account' => { 'number' => number, 'name' => name, 'account_type' => type, 'sub_type' => sub_type,
                                        'parent_id' => nil })
        end
      end

      def free_number(wanted, type, chart, rows, row)
        # Headers hold numbers too, and chart is postable accounts only.
        taken = (@taken_numbers ||= @company.chart_of_accounts.pluck(:account_number).to_set).dup
        rows.each do |r|
          next if r['qbo_account_id'] == row['qbo_account_id']

          [r.dig('choice', 'new_account', 'number'), r.dig('suggestion', 'new_account', 'number')].compact.each { |n| taken << n.to_s }
        end
        return wanted if wanted.present? && !taken.include?(wanted)

        base = { 'asset' => 1000, 'liability' => 2000, 'equity' => 3000, 'revenue' => 4000, 'expense' => 6000 }.fetch(type, 9000)
        start = wanted.to_i.positive? ? wanted.to_i : base
        (start..(start + 999)).map(&:to_s).find { |n| !taken.include?(n) } || "#{base}-#{SecureRandom.hex(2)}"
      end
    end
  end
end
