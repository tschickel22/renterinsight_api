# frozen_string_literal: true

# Tells the platform when a tenant pulls a large slice of their data out.
# System-facing, so it renders the platform brand (see BRAND KERNEL in
# CLAUDE.md), never a dealership's.
class ExportAlertMailer < ApplicationMailer
  def large_export(export_job_id)
    @job = ExportJob.find_by(id: export_job_id)
    return if @job.nil?

    @company = @job.company
    @user    = @job.user
    @brand   = Brand.current

    mail(
      to: @brand.support_email,
      from: default_from_address,
      subject: "Large export: #{@company&.name} pulled #{@job.row_count} #{@job.module_type} rows"
    )
  end
end
