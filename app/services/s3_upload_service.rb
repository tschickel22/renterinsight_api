# frozen_string_literal: true

# S3 Upload Service for Website Builder Media
# Handles uploading media files to S3 and returning CDN URLs
class S3UploadService
  require 'aws-sdk-s3'
  
  attr_reader :s3_client, :bucket_name, :region
  
  # @param bucket [String, nil] Override the default bucket. Used by callers who
  #   must NOT share the general upload bucket — currently the catalog image
  #   archiver, whose URLs are written permanently into vehicle rows and so need
  #   their own lifecycle, while customer uploads carry on where they already are.
  def initialize(bucket: nil)
    @region = ENV['AWS_REGION'] || 'us-west-2'
    @bucket_name = bucket.presence || ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging'

    @s3_client = Aws::S3::Client.new(
      region: @region,
      access_key_id: ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
    )
  rescue Aws::Errors::MissingCredentialsError => e
    Rails.logger.error("AWS credentials missing: #{e.message}")
    raise "AWS S3 credentials not configured. Check environment variables."
  end
  
  # Upload a file to S3 and return the public URL
  # @param file [ActionDispatch::Http::UploadedFile, File] The file to upload
  # @param folder [String] Optional folder path (e.g., 'websites/123/media')
  # @return [Hash] { url: String, key: String, size: Integer }
  # @param key [String, nil] Optional deterministic key. Omit for the default
  #   timestamped-random name (correct for user uploads, where two uploads of
  #   the same file are two distinct assets). Pass one when re-running an import
  #   should reuse the existing object instead of piling up duplicates.
  def upload(file, folder: 'media', key: nil)
    if key.nil?
      # Generate unique filename with timestamp
      timestamp = Time.now.to_i
      extension = File.extname(file.original_filename || file.path)
      filename = "#{timestamp}_#{SecureRandom.hex(8)}#{extension}"

      # S3 key (path in bucket)
      key = "#{folder}/#{filename}"
    end
    
    # Determine content type
    content_type = file.content_type || 'application/octet-stream'
    
    # Upload to S3
    begin
      metadata = {
        'original_filename' => file.original_filename || File.basename(file.path),
        'uploaded_at' => Time.now.iso8601
      }

      # Streamed from disk rather than read into a String first.
      #
      # `file.read` pulled the whole upload into memory before sending it, so a
      # 200MB video cost 200MB of resident heap on a box that is serving every
      # other request at the same time, and two at once could take the instance
      # out. upload_file also switches to a multipart upload on its own once the
      # object is large, which is what lets a video survive a slow connection
      # instead of restarting from zero.
      source_path = file.try(:tempfile).try(:path) || (file.respond_to?(:path) ? file.path : nil)

      if source_path && File.exist?(source_path)
        Aws::S3::Resource.new(client: s3_client)
                         .bucket(bucket_name)
                         .object(key)
                         .upload_file(source_path, content_type: content_type, metadata: metadata)
      else
        # StringIO and friends, used by the importers. Small by construction.
        s3_client.put_object(
          bucket: bucket_name,
          key: key,
          body: file.respond_to?(:read) ? file.read : File.read(file.path),
          content_type: content_type,
          # No ACL needed - bucket policy makes all objects public
          metadata: metadata
        )
      end

      # Get file size
      file_size = file.respond_to?(:size) ? file.size : File.size(file.path)
      
      # Return permanent public S3 URL
      {
        url: "https://#{bucket_name}.s3.#{region}.amazonaws.com/#{key}",
        key: key,
        size: file_size,
        content_type: content_type
      }
    rescue Aws::S3::Errors::ServiceError => e
      Rails.logger.error("S3 upload failed: #{e.message}")
      raise "Failed to upload file to S3: #{e.message}"
    end
  end
  
  # Generate a presigned URL for temporary public access (expires in 1 hour)
  # @param key [String] The S3 key (path)
  # @param expires_in [Integer] Expiration time in seconds (default: 1 hour)
  # @return [String] Presigned URL
  def presigned_url(key, expires_in: 3600)
    signer = Aws::S3::Presigner.new(client: s3_client)
    signer.presigned_url(
      :get_object,
      bucket: bucket_name,
      key: key,
      expires_in: expires_in
    )
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("Presigned URL generation failed: #{e.message}")
    nil
  end
  
  # Read an object back as raw bytes.
  #
  # For work that uploads on the request and consumes it on a background job —
  # a document scan takes minutes, so the file has to outlive the request that
  # brought it in. Returns nil rather than raising: a missing object is a
  # condition the caller reports, not an exception mid-job.
  #
  # @param key [String] The S3 key (path)
  # @return [String, nil] Binary body, or nil if unreadable
  def download(key)
    return nil if key.blank?

    s3_client.get_object(bucket: bucket_name, key: key).body.read
  rescue Aws::S3::Errors::NoSuchKey
    Rails.logger.warn("S3 download: no such key #{key}")
    nil
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("S3 download failed for #{key}: #{e.message}")
    nil
  end

  # Delete a file from S3
  # @param key [String] The S3 key (path)
  # @return [Boolean] True if successful
  def delete(key)
    s3_client.delete_object(
      bucket: bucket_name,
      key: key
    )
    true
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("S3 delete failed: #{e.message}")
    false
  end
  
  # Check if a file exists in S3
  # @param key [String] The S3 key (path)
  # @return [Boolean]
  def exists?(key)
    s3_client.head_object(
      bucket: bucket_name,
      key: key
    )
    true
  rescue Aws::S3::Errors::NotFound
    false
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("S3 exists check failed: #{e.message}")
    false
  end
  
  # List all files in a folder.
  #
  # Pages through the whole prefix. list_objects_v2 caps a response at 1,000
  # keys, so the previous single call silently truncated — a caller using this
  # to answer "have I uploaded this already?" got `false` for everything past
  # the first thousand and re-uploaded it. The catalog folder alone holds
  # several thousand images.
  #
  # @param folder [String] Folder path (e.g., 'websites/123')
  # @return [Array<String>] Array of S3 keys
  def list_files(folder)
    keys  = []
    token = nil

    loop do
      response = s3_client.list_objects_v2(
        bucket: bucket_name,
        prefix: folder,
        continuation_token: token
      )
      keys.concat(response.contents.map(&:key))
      break unless response.is_truncated

      token = response.next_continuation_token
      break if token.blank?
    end

    keys
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("S3 list failed: #{e.message}")
    []
  end
end
