# frozen_string_literal: true

require 'csv'

# A report's rows as a CSV file: a saved report's Export, and an AI answer's
# Export. The caller has already checked the person may read the module.
#
# Runs the same query the screen ran, at ReportEngine::MAX_PER_PAGE rows, and
# records the export like every other way data leaves (ExportRecorder: an
# export_jobs row, an activity log entry, the large-export alert, and the
# export_ref watermark on each row).
class ReportExport
  Result = Struct.new(:csv, :filename, :total, :rows, keyword_init: true) do
    def truncated?
      total > rows
    end
  end

  # query: module, fields, filters, sort_by, sort_order.
  def self.call(company:, user:, query:, location_id:, name:, ip: nil)
    query = query.to_h.with_indifferent_access
    result = ReportEngine.run(
      module: query[:module], fields: query[:fields], filters: query[:filters] || {},
      sort_by: query[:sort_by], sort_order: query[:sort_order] || 'desc',
      page: 1, per_page: ReportEngine::MAX_PER_PAGE,
      company_id: company.id, location_id: location_id, user: user
    )
    columns = result[:columns]
    total = result.dig(:meta, :total).to_i

    job = ImportExport::ExportRecorder.record!(
      company: company, user: user, module_type: "report:#{query[:module]}", row_count: result[:rows].size,
      scope: total > result[:rows].size ? 'first_page' : 'all_matching',
      filters: (query[:filters] || {}).to_h, columns: columns.map { |c| c[:label] }, ip: ip
    )

    csv = CSV.generate do |out|
      out << columns.map { |c| ImportExport::CsvCell.safe(c[:label].to_s) } + [ImportExport::Exporter::WATERMARK_LABEL]
      result[:rows].each do |row|
        out << columns.map { |c| ImportExport::CsvCell.safe(row[c[:key]]) } + [job.watermark_token]
      end
    end

    Result.new(csv: csv, filename: "#{name.to_s.parameterize.presence || 'report'}-#{Date.current}.csv",
               total: total, rows: result[:rows].size)
  end
end
