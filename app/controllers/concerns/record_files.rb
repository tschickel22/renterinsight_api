# frozen_string_literal: true

# Files kept on a CRM record (account, contact, lead, deal) for the team, not
# for the customer. Buyer-portal documents are PortalDocument and stay
# separate: nothing here is ever shown in the portal.
#
# Stored with Active Storage (`has_many_attached :files`), which is the
# private bucket on staging and production. A file is only handed out as a
# short-lived signed link from #download_file.
#
#   include RecordFiles
#   record_files_for :lead, finder: :set_lead, resource: 'leads'
#
# The record is loaded by the controller's own finder, so tenant isolation and
# location access are exactly what the record page itself enforces. The
# finder is called from a separate before_action on purpose: declaring
# `before_action :set_lead` a second time with another `only:` list would
# replace the controller's original one.
module RecordFiles
  extend ActiveSupport::Concern

  MAX_FILE_SIZE = 25.megabytes
  MAX_FILES_PER_UPLOAD = 20
  FILE_ACTIONS = %i[files upload_file destroy_file download_file].freeze

  class_methods do
    def record_files_for(ivar, finder:, resource:)
      define_method(:files_record_ivar) { ivar }
      define_method(:files_record_finder) { finder }
      define_method(:files_resource) { resource }
      before_action :load_files_record, only: FILE_ACTIONS
    end
  end

  # GET .../:id/files
  def files
    return unless authorize_action!(files_resource, 'read')

    attachments = files_record.files_attachments.includes(:blob).order(created_at: :desc)
    uploader_ids = attachments.filter_map { |a| a.blob.metadata['uploaded_by_id'] }.uniq
    names = @company.users.where(id: uploader_ids).to_h { |u| [u.id.to_s, [u.first_name, u.last_name].compact.join(' ')] }
    render json: { files: attachments.map { |a| file_json(a, names) } }
  end

  # POST .../:id/files   multipart: files[] (or file)
  def upload_file
    return unless authorize_action!(files_resource, 'update')

    uploads = Array(params[:files].presence || params[:file]).compact_blank
    return render(json: { error: 'Choose a file to upload' }, status: :unprocessable_entity) if uploads.empty?
    if uploads.size > MAX_FILES_PER_UPLOAD
      return render(json: { error: "Upload up to #{MAX_FILES_PER_UPLOAD} files at a time" }, status: :unprocessable_entity)
    end

    too_big = uploads.find { |u| u.respond_to?(:size) && u.size > MAX_FILE_SIZE }
    if too_big
      return render(json: { error: "#{too_big.original_filename} is over #{MAX_FILE_SIZE / 1.megabyte} MB" },
                    status: :unprocessable_entity)
    end

    blobs = uploads.map do |u|
      ActiveStorage::Blob.create_and_upload!(
        io: u.tempfile, filename: u.original_filename, content_type: u.content_type,
        metadata: { 'uploaded_by_id' => current_user.id.to_s }
      )
    end
    files_record.files.attach(blobs)
    created = files_record.files_attachments.where(blob_id: blobs.map(&:id)).includes(:blob)
    names = { current_user.id.to_s => [current_user.first_name, current_user.last_name].compact.join(' ') }
    render json: { files: created.map { |a| file_json(a, names) } }, status: :created
  end

  # DELETE .../:id/files/:file_id
  def destroy_file
    return unless authorize_action!(files_resource, 'update')

    attachment = files_record.files_attachments.find_by(id: params[:file_id])
    return render(json: { error: 'Not found' }, status: :not_found) unless attachment

    attachment.purge_later
    head :no_content
  end

  # GET .../:id/files/:file_id/download   (?inline=1 to view in the browser)
  def download_file
    return unless authorize_action!(files_resource, 'read')

    attachment = files_record.files_attachments.includes(:blob).find_by(id: params[:file_id])
    return render(json: { error: 'Not found' }, status: :not_found) unless attachment

    ActiveStorage::Current.url_options = { protocol: request.protocol, host: request.host, port: request.port }
    disposition = params[:inline].present? ? :inline : :attachment
    render json: { url: attachment.blob.url(expires_in: 5.minutes, disposition: disposition),
                   filename: attachment.blob.filename.to_s }
  end

  private

  def load_files_record
    send(files_record_finder)
  end

  def files_record
    instance_variable_get("@#{files_record_ivar}")
  end

  def file_json(attachment, names = {})
    blob = attachment.blob
    meta = blob.metadata
    {
      id: attachment.id,
      filename: blob.filename.to_s,
      content_type: blob.content_type,
      byte_size: blob.byte_size,
      # A file brought over from another system keeps the date it was added there.
      added_at: meta['original_created_at'].presence || attachment.created_at.iso8601,
      added_by: names[meta['uploaded_by_id'].to_s],
      origin: meta['origin']
    }
  end
end
