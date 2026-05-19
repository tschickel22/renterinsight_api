# frozen_string_literal: true

module ImportExport
  # Specialized importer for budget_lines.
  #
  # Differs from the standard Importer because budget lines:
  #   - belong to a specific budget (passed via job.options['budget_id'])
  #   - have a fixed monthly column layout that doesn't match CSV uploads
  #     1-to-1 (CSVs use 'Jan'/'January'/etc, model uses month_1..month_12)
  #   - resolve account_number → chart_of_account_id by looking up the
  #     company's chart of accounts
  #   - UPSERT (find_or_initialize_by chart_of_account_id) so a re-import
  #     overwrites prior values for that account instead of failing on
  #     the (budget_id, chart_of_account_id) uniqueness constraint
  class BudgetLineImporter
    BROADCAST_EVERY = 25

    MONTH_ALIASES = {
      'month_1'  => %w[jan january month1 m1 1],
      'month_2'  => %w[feb february month2 m2 2],
      'month_3'  => %w[mar march month3 m3 3],
      'month_4'  => %w[apr april month4 m4 4],
      'month_5'  => %w[may month5 m5 5],
      'month_6'  => %w[jun june month6 m6 6],
      'month_7'  => %w[jul july month7 m7 7],
      'month_8'  => %w[aug august month8 m8 8],
      'month_9'  => %w[sep sept september month9 m9 9],
      'month_10' => %w[oct october month10 m10 10],
      'month_11' => %w[nov november month11 m11 11],
      'month_12' => %w[dec december month12 m12 12]
    }.freeze

    def initialize(import_job)
      @job     = import_job
      @company = import_job.company
    end

    def process!
      @job.update!(status: 'processing', started_at: Time.current)

      budget = resolve_budget!
      unless budget.editable?
        raise "Budget '#{budget.name}' is not editable (status: #{budget.status}, consolidation: #{budget.consolidation_type})"
      end

      file_path = download_source
      parsed    = CsvParser.new(file_path).parse

      @job.update!(total_rows: parsed[:total_rows])

      mapping       = @job.column_mapping || {}
      strategy      = @job.duplicate_strategy.presence || 'update'
      created_ids   = []
      updated_snaps = []
      errors        = []

      parsed[:rows].each_with_index do |row, idx|
        row_number = idx + 2
        row_hash   = build_row_hash(row, parsed[:headers], mapping)

        ActiveRecord::Base.transaction(requires_new: true) do
          result = process_row(row_hash, budget, @company)

          if result[:error]
            errors << { row: row_number, errors: [result[:error]] }
            @job.error_count += 1
            raise ActiveRecord::Rollback
          elsif result[:skipped]
            @job.skipped_count += 1
            errors << { row: row_number, skipped: true, warnings: [result[:reason].presence || 'Skipped: no values to import'] }
          elsif result[:updated]
            updated_snaps << { id: result[:line].id, before: result[:before] }
            @job.success_count += 1
          else
            created_ids << result[:line].id
            @job.success_count += 1
          end
        rescue ActiveRecord::RecordInvalid => e
          errors << { row: row_number, errors: e.record.errors.full_messages }
          @job.error_count += 1
          raise ActiveRecord::Rollback
        rescue StandardError => e
          errors << { row: row_number, errors: [e.message] }
          @job.error_count += 1
          raise ActiveRecord::Rollback
        end

        @job.processed_rows += 1
        maybe_broadcast(idx)
      end

      # Touch the budget so callbacks fire — for standalone+location budgets
      # this rebuilds the consolidated roll-up.
      budget.touch unless Rails.env.test?

      @job.update!(
        status: 'completed',
        completed_at: Time.current,
        created_record_ids: created_ids,
        updated_record_snapshots: updated_snaps,
        error_log: errors,
        options: (@job.options || {}).merge('budget_id' => budget.id)
      )
      broadcast_progress
    rescue StandardError => e
      Rails.logger.error "[ImportExport::BudgetLineImporter] #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      @job.update!(status: 'failed', completed_at: Time.current,
                   error_log: (defined?(errors) ? errors : []) + [{ row: nil, errors: [e.message] }])
      raise
    end

    private

    def resolve_budget!
      budget_id = @job.options&.dig('budget_id') || @job.options&.dig(:budget_id)
      raise 'budget_id is required in import job options for budget_lines imports' if budget_id.blank?
      @company.budgets.find(budget_id)
    end

    # Resolves the account, sets month amounts, saves the budget line.
    # Returns a hash describing the outcome:
    #   { line:, updated: true|false, before: snapshot } on success
    #   { skipped: true }                                  if no values to import
    #   { error: 'message' }                               on lookup failure
    def process_row(row, budget, company)
      account_number = normalize_string(row['account_number'])
      account_name   = normalize_string(row['account_name'])

      if account_number.blank? && account_name.blank?
        return { error: 'Row missing both account_number and account_name' }
      end

      acct = nil
      acct ||= company.chart_of_accounts.find_by(account_number: account_number) if account_number.present?
      acct ||= company.chart_of_accounts.where('LOWER(account_number) = ?', account_number.downcase).first if account_number.present?
      acct ||= company.chart_of_accounts.where('name ILIKE ?', account_name).first if account_name.present?

      unless acct
        identifier = account_number.presence || account_name
        return { error: "Account not found: '#{identifier}'" }
      end

      line          = budget.budget_lines.find_or_initialize_by(chart_of_account_id: acct.id)
      was_persisted = line.persisted?
      snapshot      = was_persisted ? line.attributes.slice('month_1', 'month_2', 'month_3', 'month_4',
                                                            'month_5', 'month_6', 'month_7', 'month_8',
                                                            'month_9', 'month_10', 'month_11', 'month_12',
                                                            'notes', 'annual_total') : nil

      any_value_set = false
      (1..12).each do |m|
        val = row["month_#{m}"]
        next if val.nil? || (val.is_a?(String) && val.strip.empty?)
        line.public_send(:"month_#{m}=", parse_currency(val))
        any_value_set = true
      end

      if row['notes'].present?
        line.notes = row['notes'].to_s
        any_value_set = true
      end

      unless any_value_set || !was_persisted
        identifier = account_number.presence || account_name || "account ##{acct.id}"
        return { skipped: true, reason: "Skipped: no month values to import for #{identifier} (existing line left unchanged)" }
      end

      line.save!

      { line: line, updated: was_persisted, before: snapshot }
    end

    def parse_currency(value)
      return BigDecimal('0') if value.nil?
      return value if value.is_a?(BigDecimal)
      return BigDecimal(value.to_s) if value.is_a?(Numeric)

      cleaned = value.to_s.strip.gsub(/[$,\s]/, '')
      return BigDecimal('0') if cleaned.empty?

      # Treat parentheses as negative (accounting convention)
      if cleaned.start_with?('(') && cleaned.end_with?(')')
        cleaned = "-#{cleaned[1..-2]}"
      end

      BigDecimal(cleaned)
    rescue ArgumentError
      BigDecimal('0')
    end

    def normalize_string(value)
      return nil if value.nil?
      stripped = value.to_s.strip
      stripped.empty? ? nil : stripped
    end

    def download_source
      key = @job.source_file_url.to_s
      return key if File.exist?(key)
      ImportExport::S3Helper.download_to_tempfile(key)
    end

    def build_row_hash(row, headers, mapping)
      hash = {}
      headers.each_with_index do |header, i|
        db_key = mapping[header] || mapping[header.to_s]
        next unless db_key
        val = row[i]
        if hash.key?(db_key.to_s)
          next if val.nil? || (val.is_a?(String) && val.strip.empty?)
        end
        hash[db_key.to_s] = val
      end
      hash
    end

    def maybe_broadcast(idx)
      broadcast_progress if (idx % BROADCAST_EVERY).zero?
    end

    def broadcast_progress
      ActionCable.server.broadcast(
        "import_progress_#{@job.id}",
        {
          processed: @job.processed_rows,
          total: @job.total_rows,
          success: @job.success_count,
          errors: @job.error_count,
          skipped: @job.skipped_count,
          status: @job.status
        }
      )
    rescue StandardError
      nil
    end

    class << self
      # Maps a header string ('Jan', 'January', 'month_1', 'Month 1', '1')
      # to its canonical month_N key. Returns nil if no match.
      def month_key_for_header(header)
        return nil if header.nil?
        norm = header.to_s.downcase.gsub(/[^a-z0-9]/, '')
        return nil if norm.empty?

        MONTH_ALIASES.each do |canonical, aliases|
          return canonical if aliases.any? { |a| a.to_s == norm }
        end
        nil
      end

      # Suggests a CSV-header → budget-line-field mapping. Used by
      # ImportJobsController#preview to give dealers a sensible default.
      def suggest_mapping(headers)
        headers.each_with_object({}) do |header, mapping|
          key = suggest_key_for_header(header)
          mapping[header] = key if key
        end
      end

      def suggest_key_for_header(header)
        norm = header.to_s.downcase.gsub(/[^a-z0-9]/, '')
        return nil if norm.empty?

        return 'account_number' if %w[accountnumber acct account acctnumber acctno accountno acctnum accountnum].include?(norm)
        return 'account_name'   if %w[accountname acctname account].include?(norm) && norm != 'account'
        return 'account_name'   if norm == 'name'
        return 'notes'          if %w[notes note description comment comments].include?(norm)

        month_key_for_header(header)
      end
    end
  end
end
