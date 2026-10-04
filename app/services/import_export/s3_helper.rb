# frozen_string_literal: true

module ImportExport
  # Thin convenience wrapper that downloads an S3 object (by key) to a tempfile
  # so the parser/zip libraries can work on a real local path.
  class S3Helper
    def self.download_to_tempfile(key)
      return nil if key.blank?
      return key if File.exist?(key.to_s) # already local

      # A reference to the private bucket, or a bare key from before the move.
      tmp = Tempfile.new(['ie_', File.extname(PrivateFiles.locate(key)&.last.to_s)], binmode: true)
      tmp.write(PrivateFiles.read(key))
      tmp.flush
      tmp.path
    rescue StandardError => e
      Rails.logger.error "[ImportExport::S3Helper] download failed for #{key}: #{e.message}"
      raise
    end
  end
end
