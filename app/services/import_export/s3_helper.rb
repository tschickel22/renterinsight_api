# frozen_string_literal: true

module ImportExport
  # Thin convenience wrapper that downloads an S3 object (by key) to a tempfile
  # so the parser/zip libraries can work on a real local path.
  class S3Helper
    # Yields a local path for the key and removes the download afterwards.
    # The Tempfile must stay referenced while the path is in use: once it is
    # unreachable, GC finalizes it and unlinks the file, which surfaced as
    # "No such file or directory @ rb_sysopen - /tmp/ie_..." on larger uploads.
    def self.with_local_file(key)
      return yield(nil) if key.blank?
      return yield(key.to_s) if File.exist?(key.to_s) # already local

      # A reference to the private bucket, or a bare key from before the move.
      tmp = Tempfile.new(['ie_', File.extname(PrivateFiles.locate(key)&.last.to_s)], binmode: true)
      begin
        tmp.write(PrivateFiles.read(key))
        tmp.flush
      rescue StandardError => e
        Rails.logger.error "[ImportExport::S3Helper] download failed for #{key}: #{e.message}"
        raise
      end
      yield tmp.path
    ensure
      tmp&.close!
    end
  end
end
