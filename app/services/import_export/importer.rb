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
      # Modules with bespoke layouts (e.g. budget_lines, which has a
      # monthly column structure that doesn't map 1:1 to CSV uploads)
      # delegate to their own specialized importer.
      return BudgetLineImporter.new(@job).process! if @job.module_type.to_s == 'budget_lines'

      @job.update!(status: 'processing', started_at: Time.current)

      file_path = download_source
      parsed    = CsvParser.new(file_path).parse

      @job.update!(total_rows: parsed[:total_rows])

      cfg = ModuleRegistry.config_for(@job.module_type)
      raise "Unknown module: #{@job.module_type}" unless cfg

      fields = ModuleRegistry.fields_for(@job.module_type, company_id: @company.id)
      scope  = @company.public_send(cfg[:scope])

      # Lookup field definitions for resolving human-readable values → _id columns
      @lookup_defs = ModuleRegistry.lookup_fields_for(@job.module_type)
      @lookup_by_key = @lookup_defs.index_by { |f| f[:key] }

      # Whether this module supports tag assignment via the virtual 'tags' column.
      @taggable = ModuleRegistry.taggable?(@job.module_type)

      # Deferred-linking resolver: records unresolved parent lookups as
      # PendingImportLinks and back-fills foreign keys when the parent later
      # appears (this import or a future one), making import order-independent.
      @link_resolver = ImportExport::LinkResolver.new(@company, import_job: @job)

      validator = RowValidator.new(fields)
      @match_fields = (@job.duplicate_match_fields.presence || cfg[:match_fields] || []).map(&:to_s)
      detector  = DuplicateDetector.new(scope, @match_fields)

      mapping       = @job.column_mapping || {}
      strategy      = @job.duplicate_strategy.presence || 'skip'
      options       = @job.options || {}
      auto_location = options['location_id'].presence
      auto_owner    = options['owner_id'].presence

      # Per-import default values for unmapped fields (e.g. { status: 'new' } so
      # imported Leads land in the active list when the CSV has no Status column).
      # Restricted to real model attributes (standard/custom) — virtual fields
      # like 'tags' and lookup keys are filled through their dedicated paths.
      @default_values     = (options['default_values'] || {}).to_h
      @default_field_keys = fields.select { |f| %w[standard custom].include?(f[:source].to_s) }
                                  .map { |f| f[:key].to_s }
                                  .to_set
      created_ids   = []
      updated_snaps = []
      errors        = []

      parsed[:rows].each_with_index do |row, idx|
        row_number = idx + 2 # +1 header, +1 1-based
        row_hash   = build_row_hash(row, parsed[:headers], mapping)

        # Extract the virtual 'tags' column (if present) before validation/save —
        # the value is a free-text string that will be parsed and resolved to
        # Tag records after the record itself is saved.
        tag_names = @taggable ? extract_tag_names!(row_hash) : []

        # Resolve lookup fields (e.g. "account_name" → account_id) before validation.
        # Unresolvable lookups are warnings, not blocking errors — the deal is still
        # created without that association. Deferrable misses (non-auto-create
        # parents that simply haven't been imported yet) are captured so a
        # PendingImportLink can be recorded after the child is saved.
        lookup_result   = resolve_lookups!(row_hash)
        lookup_warnings = lookup_result[:warnings]
        lookup_misses   = lookup_result[:misses]

        # Fill blank attrs from the per-import default_values bag (any actual CSV
        # value wins; unknown field keys are silently ignored).
        apply_default_values!(row_hash)

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
          saved_record =
            if existing
              handle_duplicate(existing, data, strategy, scope, created_ids, updated_snaps, errors, row_number)
            else
              record = scope.new(data[:standard])
              record.location_id = auto_location if auto_location && record.respond_to?(:location_id=) && record.location_id.blank?
              record.owner_id = auto_owner if auto_owner && record.respond_to?(:owner_id=) && record.owner_id.blank?
              apply_custom_fields(record, data[:custom])
              apply_import_skip_flags!(record)
              record.save!
              created_ids << record.id
              @job.success_count += 1
              record
            end

          # Apply tags to the saved/updated record. Per-tag failures are
          # captured as warnings and never bubble out to roll back the row.
          tag_warnings = saved_record ? assign_tags!(saved_record, tag_names) : []

          if saved_record
            # (a) Record any deferrable lookup misses so the child re-links when
            #     its parent is imported later (this run or a future session).
            lookup_misses.each do |miss|
              @link_resolver.record_miss!(
                child_record: saved_record,
                defn:         miss[:defn],
                lookup_value: miss[:value]
              )
            end

            # (b) This new record may itself be a parent that earlier-imported
            #     children were waiting on — back-fill their foreign keys now.
            @link_resolver.resolve_for_parent!(saved_record)
          end

          # Record lookup + tag warnings (non-blocking) so user can see skipped associations
          combined_warnings = lookup_warnings + tag_warnings
          if combined_warnings.any?
            errors << { row: row_number, warnings: combined_warnings }
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
      log_import_summary_activity!(cfg)
      broadcast_progress
    rescue StandardError => e
      Rails.logger.error "[ImportExport::Importer] #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      @job.update!(status: 'failed', completed_at: Time.current, error_log: (errors || []) + [{ row: nil, errors: [e.message] }])
      raise
    end

    private

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
        # When multiple CSV columns map to the same db field (e.g. "Phone"
        # and "Secondary phone number" both → phone), keep the first
        # non-blank value instead of letting a later blank column overwrite it.
        if hash.key?(db_key.to_s)
          next if val.nil? || (val.is_a?(String) && val.strip.empty?)
        end
        hash[db_key.to_s] = val
      end
      hash
    end

    def split_custom_fields(transformed, fields)
      custom_keys = fields.select { |f| f[:source] == 'custom' }.map { |f| f[:key] }
      standard = transformed.reject { |k, _| custom_keys.include?(k) }
      custom   = transformed.select { |k, _| custom_keys.include?(k) }
      { standard: standard, custom: custom }
    end

    # Resolves virtual lookup fields in-place. For each lookup key present in
    # the row_hash (e.g. "account_name" => "ABC Corp"), searches the company's
    # records and replaces it with the real _id column (e.g. "account_id" => 42).
    # Unresolvable lookups are silently skipped (the association is left blank)
    # rather than failing the entire row, since these are optional associations.
    #
    # Returns { warnings: [String], misses: [{ defn:, value: }] }. A "miss" is a
    # non-auto-create lookup whose parent wasn't found — these are deferrable and
    # get recorded as PendingImportLinks by the caller so they re-link when the
    # parent is imported later. Auto-create lookups never defer (they create the
    # parent inline), and resolved lookups produce neither a warning nor a miss.
    def resolve_lookups!(row_hash)
      warnings = []
      misses   = []

      @lookup_by_key.each do |key, defn|
        raw_value = row_hash.delete(key)
        next if raw_value.nil? || (raw_value.is_a?(String) && raw_value.strip.empty?)

        value = raw_value.to_s.strip
        target = defn[:target_column]

        # Skip if the target _id is already set (e.g. auto-assigned location_id)
        next if row_hash[target].present?

        record = find_lookup_record(defn, value)
        if record
          row_hash[target] = record.id
        elsif defn[:auto_create]
          created = auto_create_lookup(defn, value)
          if created
            row_hash[target] = created.id
            label_name = defn[:label].to_s.split('(').first.strip
            Rails.logger.info "[ImportExport::Importer] Auto-created #{label_name}: '#{value}' (id=#{created.id})"
            warnings << "Auto-created #{label_name}: '#{value}'"
          else
            warnings << "#{defn[:label]}: could not find or create '#{value}' (skipped)"
          end
        else
          # Parent not found and not auto-creatable — defer. Record a miss so a
          # PendingImportLink is written after the child saves; the child will
          # re-link automatically when the parent is imported.
          Rails.logger.info "[ImportExport::Importer] Lookup miss (deferred): #{defn[:label]} '#{value}' — will link when parent appears"
          warnings << "#{defn[:label]}: '#{value}' not found yet — will link automatically when imported"
          misses << { defn: defn, value: value }
        end
      end

      { warnings: warnings, misses: misses }
    end

    # Searches company-scoped records for a lookup match.
    # For name-based lookups with first_name/last_name fields, supports:
    #   - "Benny" → matches first_name OR last_name
    #   - "Benny Smith" → matches first_name='Benny' AND last_name='Smith'
    #   - Also tries CONCAT(first_name, ' ', last_name) ILIKE for full name match
    def find_lookup_record(defn, value)
      scope_sym = defn[:scope]
      base = @company.respond_to?(scope_sym) ? @company.public_send(scope_sym) : defn[:model].safe_constantize
      return nil unless base

      search_fields = defn[:search_fields]

      # Special handling for first_name + last_name combo fields
      if search_fields.include?('first_name') && search_fields.include?('last_name')
        return find_by_name(base, value)
      end

      # Standard lookup: try exact match on each field, then ILIKE
      search_fields.each do |field|
        found = base.find_by(field => value)
        return found if found
      end

      conditions = search_fields.map { |f| "#{f} ILIKE ?" }.join(' OR ')
      placeholders = search_fields.map { value }
      base.where(conditions, *placeholders).first
    end

    # Auto-creates a missing lookup record within the company scope. Only invoked
    # when the lookup definition is marked `auto_create: true` (e.g. Source,
    # Account, PartCategory, Contact). Returns the new record, or nil on
    # validation failure / unsupported model.
    def auto_create_lookup(defn, value)
      scope_sym = defn[:scope]
      base = @company.respond_to?(scope_sym) ? @company.public_send(scope_sym) : nil
      return nil unless base

      attrs =
        case defn[:model]
        when 'Source'       then { name: value }
        when 'Account'      then { name: value, status: 'active', account_type: 'prospect' }
        when 'PartCategory' then { name: value, active: true }
        when 'Contact'
          # contact_email lookup → use the email; contact_name → split "First Last"
          if Array(defn[:search_fields]).include?('email')
            { email: value, first_name: value.split('@').first.presence || value }
          else
            parts = value.strip.split(/\s+/, 2)
            { first_name: parts[0], last_name: parts[1].to_s }
          end
        end

      return nil unless attrs

      record = base.new(attrs)
      apply_import_skip_flags!(record)
      record.save!
      record
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn "[ImportExport::Importer] Auto-create failed for #{defn[:model]} '#{value}': #{e.message}"
      nil
    end

    # Name-aware search: handles "Benny", "Benny Smith", "benny smith"
    def find_by_name(base, value)
      parts = value.strip.split(/\s+/, 2)

      if parts.length >= 2
        first_part, last_part = parts
        # Try exact first+last
        found = base.find_by(first_name: first_part, last_name: last_part)
        return found if found

        # Try case-insensitive first+last
        found = base.where('first_name ILIKE ? AND last_name ILIKE ?', first_part, last_part).first
        return found if found
      end

      # Try full name concat match (handles "Benny Smith" against first_name=Benny, last_name=Smith)
      found = base.where("CONCAT(first_name, ' ', last_name) ILIKE ?", value.strip).first
      return found if found

      # Single name: try first_name or last_name individually
      found = base.find_by(first_name: value.strip)
      return found if found

      found = base.find_by(last_name: value.strip)
      return found if found

      # Case-insensitive fallback
      base.where('first_name ILIKE ? OR last_name ILIKE ?', value.strip, value.strip).first
    end

    def apply_custom_fields(record, custom)
      return if custom.empty?
      return unless record.respond_to?(:custom_field_values)
      current = record.custom_field_values || {}
      record.custom_field_values = current.merge(custom)
    end

    # Returns the saved/updated record on success, or nil if no record was
    # persisted (skip / error strategies). Callers use the return value to
    # decide whether to run downstream per-row work like tag assignment.
    def handle_duplicate(existing, data, strategy, scope, created_ids, updated_snaps, errors, row_number)
      case strategy
      when 'skip'
        @job.skipped_count += 1
        errors << { row: row_number, skipped: true, warnings: [skip_reason(existing, data[:standard])] }
        nil
      when 'update'
        snapshot = existing.attributes.slice(*data[:standard].keys)
        existing.assign_attributes(data[:standard])
        apply_custom_fields(existing, data[:custom])
        apply_import_skip_flags!(existing)
        existing.save!
        updated_snaps << { id: existing.id, before: snapshot }
        @job.success_count += 1
        existing
      when 'create_new'
        record = scope.new(data[:standard])
        apply_custom_fields(record, data[:custom])
        apply_import_skip_flags!(record)
        record.save!
        created_ids << record.id
        @job.success_count += 1
        record
      when 'error'
        errors << { row: row_number, errors: ['Duplicate record exists'] }
        @job.error_count += 1
        nil
      end
    end

    # Writes a single ActivityLog row summarizing the import — replaces the
    # per-record entries that ActivityTrackable would otherwise have created
    # before we set skip_activity_tracking on each saved record. Best-effort:
    # any failure (missing model, missing column, validation drift) is logged
    # and swallowed so a logging hiccup never marks the job failed.
    def log_import_summary_activity!(cfg)
      return unless defined?(ActivityLog)
      label = cfg[:label].to_s
      module_label = label.empty? ? @job.module_type.to_s : label.downcase
      description = "Imported #{@job.success_count} #{module_label} " \
                    "(#{@job.skipped_count} skipped, #{@job.error_count} errors)"

      ActivityLog.create!(
        company_id:        @company.id,
        user_id:           @job.user_id,
        action:            'import',
        module_name:       @job.module_type.to_s,
        entity_type_label: label.presence || @job.module_type.to_s.titleize,
        description:       description,
        metadata: {
          'import_job_id'    => @job.id,
          'module_type'      => @job.module_type.to_s,
          'source_filename'  => @job.source_filename,
          'total_rows'       => @job.total_rows,
          'success_count'    => @job.success_count,
          'skipped_count'    => @job.skipped_count,
          'error_count'      => @job.error_count
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[ImportExport::Importer] Failed to write import summary ActivityLog for job ##{@job.id}: #{e.message}"
    end

    # Suppresses per-record side effects (notifications, webhooks, activity
    # logs, workflow triggers) while the bulk importer saves a record. All
    # four flags live on ApplicationRecord so every AR descendant responds.
    # A single summary ActivityLog row is written by the importer itself
    # after the run completes, in place of the per-row entries we suppress.
    def apply_import_skip_flags!(record)
      record.skip_notifications     = true
      record.skip_webhooks          = true
      record.skip_activity_tracking = true
      record.skip_workflows         = true
    end

    # Fills blank attrs from the per-import default_values bag. Mutates row_hash.
    # Only applies to keys whose target field is a real model attribute (standard
    # or custom) — virtual lookups and 'tags' have their own paths. Unknown keys
    # are silently dropped, which keeps the API forward-compatible with frontend
    # versions that send keys older models don't define.
    def apply_default_values!(row_hash)
      return if @default_values.empty?
      @default_values.each do |key, value|
        k = key.to_s
        next unless @default_field_keys.include?(k)
        next if row_hash[k].present?
        row_hash[k] = value
      end
    end

    # Removes the virtual 'tags' column from row_hash and returns the parsed
    # list of tag names. Supports pipe and comma separators (so 'VIP|Hot Lead,
    # Trade Show' yields ['VIP', 'Hot Lead', 'Trade Show']). Case-preserving
    # at this stage — case-insensitive matching happens during resolution.
    def extract_tag_names!(row_hash)
      raw = row_hash.delete('tags')
      parse_tag_list(raw)
    end

    def parse_tag_list(raw)
      return [] if raw.nil?
      values = raw.is_a?(Array) ? raw : raw.to_s.split(/[|,]/)
      values.map { |v| v.to_s.strip }.reject(&:empty?).uniq { |v| v.downcase }
    end

    # For each tag name on the row, find-or-create the Tag (case-insensitive,
    # company-scoped) and attach it to the saved record via TagAssignment.
    # Per-tag failures are captured as warning strings and returned; they do
    # not raise, so a tag problem never rolls back a successful record save.
    def assign_tags!(record, tag_names)
      return [] if tag_names.empty?
      warnings = []
      entity_type = record.class.name

      tag_names.each do |raw_name|
        name = raw_name.to_s.strip
        next if name.blank?

        begin
          tag = find_or_create_tag!(name)
          TagAssignment.find_or_create_by!(
            tag_id:      tag.id,
            entity_type: entity_type,
            entity_id:   record.id
          ) do |a|
            a.company_id  = @company.id
            a.assigned_by = @job.user_id&.to_s
            a.assigned_at = Time.current
          end
        rescue ActiveRecord::RecordInvalid => e
          warnings << "Tag '#{name}': #{e.record.errors.full_messages.join(', ')} (skipped)"
        rescue StandardError => e
          Rails.logger.warn "[ImportExport::Importer] Tag assignment failed for '#{name}' on #{entity_type} ##{record.id}: #{e.message}"
          warnings << "Tag '#{name}': could not assign (skipped)"
        end
      end

      warnings
    end

    # Case-insensitive find within the company scope; creates a new Tag with
    # the supplied name (case preserved as given) if no match exists.
    def find_or_create_tag!(name)
      existing = @company.tags.where('LOWER(name) = ?', name.downcase).first
      return existing if existing

      @company.tags.create!(
        name:       name,
        color:      '#6B7280',
        is_active:  true,
        created_by: @job.user_id&.to_s
      )
    end

    def skip_reason(existing, row_data)
      fields = Array(@match_fields).select { |f| row_data[f].present? }
      match_summary = fields.map { |f| "#{f}=#{row_data[f].to_s.truncate(60)}" }.join(', ')
      base = "Skipped: duplicate of existing record ##{existing.id}"
      match_summary.present? ? "#{base} (matched on #{match_summary})" : base
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
