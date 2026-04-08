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
      records = apply_filters(@company.public_send(cfg[:scope]), @job.filters)

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
        (record.respond_to?(:custom_field_values) ? (record.custom_field_values || {}) : {})[field[:key]]
      elsif record.respond_to?(field[:key])
        record.public_send(field[:key])
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
