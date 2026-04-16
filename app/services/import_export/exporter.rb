# frozen_string_literal: true

require 'csv'
require 'caxlsx'

module ImportExport
  # Generates CSV/XLSX/JSON files from a company-scoped query.
  # The S3 upload step is wired in Chunk C; for now files land in tmp/exports.
  class Exporter
    def initialize(export_job)
      @job     = export_job
      @company = export_job.company
    end

    def process!
      @job.update!(status: 'processing', started_at: Time.current)

      cfg = ModuleRegistry.config_for(@job.module_type)
      raise "Unknown module: #{@job.module_type}" unless cfg

      fields  = ModuleRegistry.fields_for(@job.module_type, company_id: @company.id)
      keys    = (@job.selected_fields.presence || fields.map { |f| f[:key] }).map(&:to_s)
      scope   = apply_filters(@company.public_send(cfg[:scope]), @job.filters)

      # Eager-load associations that will be resolved to display names
      includes_list = keys.filter_map do |k|
        display = ModuleRegistry.association_display_for(@job.module_type, k)
        display[:association] if display
      end

      if includes_list.any?
        # Only include associations that actually exist on the model
        model_class = ModuleRegistry.model_class(@job.module_type)
        valid_associations = model_class.reflect_on_all_associations.map(&:name)
        includes_list = includes_list.select { |a| valid_associations.include?(a) }
        scope = scope.includes(*includes_list) if includes_list.any?
      end

      Rails.logger.info "[ImportExport::Exporter] module=#{@job.module_type} keys=#{keys.inspect} includes=#{includes_list.inspect}"

      records = scope

      path = case @job.format
             when 'csv'  then write_csv(records, fields, keys)
             when 'xlsx' then write_xlsx(records, fields, keys)
             when 'json' then write_json(records, fields, keys)
             else raise "Unsupported format: #{@job.format}"
             end

      @job.update!(
        status: 'completed',
        completed_at: Time.current,
        row_count: records.size,
        file_url: path
      )
    rescue StandardError => e
      Rails.logger.error "[ImportExport::Exporter] #{e.class}: #{e.message}"
      @job.update!(status: 'failed', completed_at: Time.current)
      raise
    end

    private

    def apply_filters(scope, filters)
      return scope if filters.blank?
      filters.each do |k, v|
        scope = scope.where(k => v) if scope.column_names.include?(k.to_s)
      end
      scope
    end

    def value_for(record, field)
      if field[:source] == 'custom'
        raw = (record.respond_to?(:custom_field_values) ? (record.custom_field_values || {}) : {})[field[:key]]
        return format_value(raw)
      end

      return nil unless record.respond_to?(field[:key])

      raw = record.public_send(field[:key])
      return nil if raw.nil?

      # For _id columns, resolve to human-readable name
      display = ModuleRegistry.association_display_for(@job.module_type, field[:key])
      if display
        begin
          related = record.public_send(display[:association])
        rescue StandardError
          related = nil
        end

        if related
          # Try each display attribute in order
          display[:attrs].each do |attr|
            next unless related.respond_to?(attr)
            val = related.public_send(attr)
            return val if val.present?
          end

          # Last resort for models with first_name/last_name
          if related.respond_to?(:first_name) && related.respond_to?(:last_name)
            full = [related.first_name, related.last_name].compact.join(' ')
            return full if full.present?
          end
        end

        # If association resolution was attempted but failed, return nil
        # (don't leak raw integer IDs into exports)
        return nil
      end

      format_value(raw)
    end

    # Convert JSONB arrays/hashes into human-readable cell values.
    # Empty collections → nil (blank cell). Non-empty ones → readable text.
    def format_value(val)
      case val
      when Array
        return nil if val.empty?
        # Complex structures (array of hashes) → JSON string for round-trip
        if val.first.is_a?(Hash)
          val.to_json
        else
          val.map { |v| format_value(v) }.compact.join(', ')
        end
      when Hash
        val.empty? ? nil : val.to_json
      when true
        'Yes'
      when false
        'No'
      else
        val
      end
    end

    def output_path(ext)
      dir = Rails.root.join('tmp', 'exports')
      FileUtils.mkdir_p(dir)
      dir.join("export_#{@job.id}_#{Time.current.to_i}.#{ext}").to_s
    end

    def write_csv(records, fields, keys)
      selected = fields.select { |f| keys.include?(f[:key]) }
      path = output_path('csv')
      CSV.open(path, 'w') do |csv|
        csv << selected.map { |f| f[:label] || f[:key] }
        records.find_each do |r|
          csv << selected.map { |f| value_for(r, f) }
        end
      end
      path
    end

    def write_xlsx(records, fields, keys)
      selected = fields.select { |f| keys.include?(f[:key]) }
      path = output_path('xlsx')
      package = Axlsx::Package.new
      package.workbook.add_worksheet(name: @job.module_type[0, 31]) do |sheet|
        sheet.add_row(selected.map { |f| f[:label] || f[:key] })
        records.find_each do |r|
          sheet.add_row(selected.map { |f| value_for(r, f) })
        end
      end
      package.serialize(path)
      path
    end

    def write_json(records, fields, keys)
      selected = fields.select { |f| keys.include?(f[:key]) }
      path = output_path('json')
      data = records.map { |r| selected.each_with_object({}) { |f, h| h[f[:key]] = value_for(r, f) } }
      File.write(path, data.to_json)
      path
    end
  end
end
