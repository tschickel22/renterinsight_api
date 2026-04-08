# frozen_string_literal: true

module ImportExport
  # Thin convenience wrapper that downloads an S3 object (by key) to a tempfile
  # so the parser/zip libraries can work on a real local path.
  class S3Helper
    def self.download_to_tempfile(key)
      return nil if key.blank?
      return key if File.exist?(key.to_s) # already local

      svc = S3UploadService.new
      tmp = Tempfile.new(['ie_', File.extname(key)], binmode: true)
      resp = svc.s3_client.get_object(bucket: svc.bucket_name, key: key)
      tmp.write(resp.body.read)
      tmp.flush
      tmp.path
    rescue StandardError => e
      Rails.logger.error "[ImportExport::S3Helper] download failed for #{key}: #{e.message}"
      raise
    end

    def self.upload_file(local_path, folder: 'imports')
      svc = S3UploadService.new
      key = "#{folder}/#{Time.now.to_i}_#{SecureRandom.hex(6)}#{File.extname(local_path)}"
      svc.s3_client.put_object(
        bucket: svc.bucket_name,
        key: key,
        body: File.read(local_path),
        content_type: 'application/octet-stream'
      )
      key
    end
  end
end
