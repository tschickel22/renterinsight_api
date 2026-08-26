# frozen_string_literal: true

# Export hardening: an export is now an audited, acknowledged, watermarked
# event rather than an anonymous file drop. See ImportExport::ExportPolicy.
class AddExportControlsToExportJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :export_jobs, :acknowledged_at,      :datetime
    add_column :export_jobs, :acknowledgement_text, :text
    add_column :export_jobs, :watermark_token,      :string
    add_column :export_jobs, :requested_ip,         :string
    add_column :export_jobs, :downloaded_at,        :datetime
    add_column :export_jobs, :download_count,       :integer, default: 0, null: false
    add_column :export_jobs, :error_message,         :text

    # Backs the per-user daily rate limit lookup in ExportPolicy.
    add_index :export_jobs, %i[company_id user_id created_at],
              name: 'index_export_jobs_on_company_user_created'
    add_index :export_jobs, :watermark_token
  end
end
