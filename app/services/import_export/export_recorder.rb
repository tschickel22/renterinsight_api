# frozen_string_literal: true

module ImportExport
  # Records an export that did not go through the Exporter: a list page or
  # report the browser assembled from the list's own endpoints, or a
  # controller that streams its own CSV. Same record the Exporter leaves (an
  # export_jobs row, an activity log entry, a watermark, the large-export
  # alert), so every way data leaves shows up in one place.
  #
  # Monitored, never refused. The tenant's daily limit and row cap apply only
  # to the Import/Export builder.
  class ExportRecorder
    # => the ExportJob, whose watermark_token goes on every row.
    def self.record!(company:, user:, module_type:, row_count:, scope:, filters: {}, columns: [], ip: nil)
      now = Time.current
      job = ExportJob.create!(
        company_id: company.id,
        user_id: user.id,
        module_type: module_type.to_s.first(100),
        format: 'csv',
        filters: (filters || {}).to_h.deep_stringify_keys.merge('export_scope' => scope.to_s.first(50)),
        selected_fields: Array(columns).map { |c| c.to_s.first(200) },
        status: 'completed',
        row_count: row_count.to_i,
        started_at: now,
        completed_at: now,
        downloaded_at: now,
        download_count: 1,
        watermark_token: ExportPolicy.new_watermark_token,
        requested_ip: ip
      )

      log!(job, scope)
      alert!(job, company)
      job
    end

    def self.log!(job, scope)
      ActivityLog.create!(
        company_id: job.company_id,
        user_id: job.user_id,
        action: 'export_downloaded',
        module_name: 'data_import_export',
        entity_type_label: 'Export',
        description: "Exported #{job.row_count} rows of #{job.module_type} (#{scope})",
        ip_address: job.requested_ip,
        metadata: {
          'export_job_id'   => job.id,
          'module_type'     => job.module_type,
          'format'          => job.format,
          'field_count'     => job.selected_fields.size,
          'row_count'       => job.row_count,
          'watermark_token' => job.watermark_token,
          'filters'         => job.filters
        }
      )
    rescue StandardError => e
      Rails.logger.warn "[ExportRecorder] Failed to write ActivityLog for job ##{job.id}: #{e.message}"
    end

    def self.alert!(job, company)
      threshold = ExportPolicy.alert_threshold(company)
      return if threshold <= 0 || job.row_count < threshold

      ExportAlertMailer.large_export(job.id).deliver_later
    rescue StandardError => e
      Rails.logger.warn "[ExportRecorder] Failed to send large-export alert for job ##{job.id}: #{e.message}"
    end
  end
end
