# frozen_string_literal: true

module ImportExport
  # Orchestrates a single ImportJob: parse → validate → dedup → write.
  # Each row is wrapped in its own savepoint so a single bad row never
  # poisons the rest of the file.
  class Importer
    BROADCAST_EVERY = 25

    def initialize(import_job)
      @job     = import_job
      @company = import_job.company
    end

    def process!
      @job.update!(status: 'processing', started_at: Time.current)

      file_path = download_source
      parsed    = CsvParser.new(file_path).parse

      @job.update!(total_rows: parsed[:total_rows])

      cfg = ModuleRegistry.config_for(@job.module_type)
      raise "Unknown module: #{@job.module_type}" unless cfg

      fields = ModuleRegistry.fields_for(@job.module_type, company_id: @company.id)
      scope  = @company.public_send(cfg[:scope])

      validator = RowValidator.new(fields)
      detector  = DuplicateDetector.new(scope, @job.duplicate_match_fields.presence || cfg[:match_fields])

      mapping       = @job.column_mapping || {}
      strategy      = @job.duplicate_strategy.presence || 'skip'
      created_ids   = []
      updated_snaps = []
      errors        = []

      parsed[:rows].each_with_index do |row, idx|
        row_number = idx + 2 # +1 header, +1 1-based
        row_hash   = build_row_hash(row, parsed[:headers], mapping)

        result = validator.call(row_hash)
        unless result[:valid]
          errors << { row: row_number, errors: result[:errors] }
          @job.error_count += 1
          @job.processed_rows += 1
          maybe_broadcast(idx)
          next
        end

        data = split_custom_fields(result[:transformed_data], fields)

        ActiveRecord::Base.transaction(requires_new: true) do
          existing = detector.find(data[:standard])
          if existing
            handle_duplicate(existing, data, strategy, scope, created_ids, updated_snaps, errors, row_number)
          else
            record = scope.new(data[:standard])
            apply_custom_fields(record, data[:custom])
            record.save!
            created_ids << record.id
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

      process_images!(created_ids) if @job.image_zip_url.present? && ModuleRegistry.supports_images?(@job.module_type)

      @job.update!(
        status: 'completed',
        completed_at: Time.current,
        created_record_ids: created_ids,
        updated_record_snapshots: updated_snaps,
        error_log: errors
      )
      broadcast_progress
    rescue StandardError => e
      Rails.logger.error "[ImportExport::Importer] #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      @job.update!(status: 'failed', completed_at: Time.current, error_log: (errors || []) + [{ row: nil, errors: [e.message] }])
      raise
    end

    private

    def download_source
      # Local-path support for tests / dev. S3 download wired in Chunk C.
      return @job.source_file_url if File.exist?(@job.source_file_url.to_s)
      raise "Source file not accessible: #{@job.source_file_url}"
    end

    def build_row_hash(row, headers, mapping)
      hash = {}
      headers.each_with_index do |header, i|
        db_key = mapping[header] || mapping[header.to_s]
        next unless db_key
        hash[db_key.to_s] = row[i]
      end
      hash
    end

    def split_custom_fields(transformed, fields)
      custom_keys = fields.select { |f| f[:source] == 'custom' }.map { |f| f[:key] }
      standard = transformed.reject { |k, _| custom_keys.include?(k) }
      custom   = transformed.select { |k, _| custom_keys.include?(k) }
      { standard: standard, custom: custom }
    end

    def apply_custom_fields(record, custom)
      return if custom.empty?
      return unless record.respond_to?(:custom_field_values)
      current = record.custom_field_values || {}
      record.custom_field_values = current.merge(custom)
    end

    def handle_duplicate(existing, data, strategy, scope, created_ids, updated_snaps, errors, row_number)
      case strategy
      when 'skip'
        @job.skipped_count += 1
      when 'update'
        snapshot = existing.attributes.slice(*data[:standard].keys)
        existing.assign_attributes(data[:standard])
        apply_custom_fields(existing, data[:custom])
        existing.save!
        updated_snaps << { id: existing.id, before: snapshot }
        @job.success_count += 1
      when 'create_new'
        record = scope.new(data[:standard])
        apply_custom_fields(record, data[:custom])
        record.save!
        created_ids << record.id
        @job.success_count += 1
      when 'error'
        errors << { row: row_number, errors: ['Duplicate record exists'] }
        @job.error_count += 1
      end
    end

    def process_images!(created_ids)
      ImageMatcher.new(@job, created_ids).match_and_attach!
    rescue StandardError => e
      Rails.logger.warn "[ImportExport::Importer] Image processing failed: #{e.message}"
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
  end
end
