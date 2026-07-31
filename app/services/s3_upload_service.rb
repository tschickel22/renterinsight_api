# frozen_string_literal: true

# S3 Upload Service for Website Builder Media
# Handles uploading media files to S3 and returning CDN URLs
class S3UploadService
  require 'aws-sdk-s3'
  
  attr_reader :s3_client, :bucket_name, :region
  
  def initialize
    @region = ENV['AWS_REGION'] || 'us-west-2'
    @bucket_name = ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging'
    
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
      s3_client.put_object(
        bucket: bucket_name,
        key: key,
        body: file.respond_to?(:read) ? file.read : File.read(file.path),
        content_type: content_type,
        # No ACL needed - bucket policy makes all objects public
        metadata: {
          'original_filename' => file.original_filename || File.basename(file.path),
          'uploaded_at' => Time.now.iso8601
        }
      )
      
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
