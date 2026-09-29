# frozen_string_literal: true

require 'aws-sdk-s3'

# Confidential files: signed agreements, bills, receipts, imports, contractor
# photos, project and vehicle documents, anything a dealer or their customer
# would not want on the open internet.
#
# These used to go to AWS_S3_BUCKET, which is PUBLIC by bucket policy so dealer
# websites can load images from it. Anyone holding a link could read a signed
# agreement forever. They now go to PRIVATE_DOCUMENTS_BUCKET (Block Public
# Access on, encrypted, versioned) and are only ever handed out as presigned
# URLs that expire.
#
# What gets stored is a reference, "s3://bucket/key", never a URL. Rows written
# before the move hold a public URL or a bare key in the old bucket; every
# method here accepts all three, so old rows keep working until
# `bin/rails private_files:migrate` rewrites them.
#
# Never store what `url` returns. It expires. Anything the browser sends back
# goes through `normalize` first, which turns a presigned or legacy URL back
# into a reference.
module PrivateFiles
  class NotConfigured < StandardError; end
  class Forbidden < StandardError; end

  SCHEME = 's3://'
  DEFAULT_TTL = 1.hour
  # Every folder is "<area>/<company_id>/...", except these.
  COMPANY_SEGMENT = Hash.new(1).merge('site-profiles' => 2).freeze
  LEGACY_DEFAULT_BUCKET = 'renterinsight-website-assets-staging'

  module_function

  def bucket
    ENV['PRIVATE_DOCUMENTS_BUCKET'].presence ||
      raise(NotConfigured, 'PRIVATE_DOCUMENTS_BUCKET is not set. Confidential files will not be written to the public bucket.')
  end

  # Where confidential files lived before the move.
  def legacy_bucket
    ENV['AWS_S3_BUCKET'].presence || LEGACY_DEFAULT_BUCKET
  end

  def known_buckets
    [ENV['PRIVATE_DOCUMENTS_BUCKET'].presence, legacy_bucket].compact.uniq
  end

  def client
    @client ||= Aws::S3::Client.new(region: ENV['AWS_REGION'] || 'us-west-2',
                                    access_key_id: ENV['AWS_ACCESS_KEY_ID'],
                                    secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'])
  end

  def ref(key, bucket_name = bucket)
    "#{SCHEME}#{bucket_name}/#{key}"
  end

  # Upload an uploaded file (or anything S3UploadService#upload takes).
  # @return [Hash] { ref:, key:, size:, content_type: }
  def upload(file, folder:)
    result = S3UploadService.new(bucket: bucket).upload(file, folder: folder)
    { ref: ref(result[:key]), key: result[:key], size: result[:size], content_type: result[:content_type] }
  end

  # Upload bytes we generated (a sealed PDF, a merged document).
  # @return [String] the reference
  def put(body, key:, content_type: 'application/octet-stream')
    client.put_object(bucket: bucket, key: key, body: body, content_type: content_type)
    ref(key)
  end

  # [bucket, key] for a file we stored, nil for anything else (blank, data
  # URIs, other hosts, buckets that are not ours).
  def locate(value)
    v = value.to_s.strip
    return nil if v.empty? || v.start_with?('data:')

    b, k =
      if v.start_with?(SCHEME)
        v.delete_prefix(SCHEME).split('/', 2)
      elsif v.match?(%r{\Ahttps?://}i)
        from_url(v)
      elsif v.include?('/') && !v.include?(':')
        # Bare keys, as import jobs and campaign steps stored them.
        [legacy_bucket, v.delete_prefix('/')]
      end
    return nil if k.blank? || !known_buckets.include?(b)

    [b, k]
  end

  def located?(value) = !locate(value).nil?

  # The value to store: a reference for anything in our buckets (including a
  # presigned URL the browser sent back), otherwise the value unchanged.
  def normalize(value)
    loc = locate(value)
    loc ? ref(loc[1], loc[0]) : value
  end

  # A link the browser can open, valid for `expires_in`. Data URIs and URLs on
  # other hosts pass through untouched; a reference to a bucket we do not know
  # comes back nil rather than as something unusable.
  def url(value, expires_in: DEFAULT_TTL, filename: nil, disposition: 'inline')
    return nil if value.blank?

    b, k = locate(value)
    unless k
      return nil if value.to_s.start_with?(SCHEME)

      return value
    end

    params = { bucket: b, key: k, expires_in: expires_in.to_i }
    if filename.present?
      safe = filename.to_s.gsub(/["\\\r\n]/, '')
      params[:response_content_disposition] = %(#{disposition}; filename="#{safe}")
    end
    Aws::S3::Presigner.new(client: client).presigned_url(:get_object, **params)
  end

  # A link that keeps working when stored somewhere we do not control, such as
  # a custom field value. It carries the reference in a signed token and
  # redirects to a fresh presigned URL on each open. Like a tracked link it is
  # a bearer link: unguessable and revocable (delete the file), but anyone
  # holding it can open the file. Prefer `url` wherever the JSON is ours.
  def durable_url(value)
    loc = locate(value)
    return value unless loc

    token = verifier.generate(ref(loc[1], loc[0]), purpose: :private_file)
    "#{Messaging::TrackingUrl.base}/pf/#{token}"
  end

  # The reference inside a durable_url token, or nil if it was tampered with.
  def from_durable_token(token)
    verifier.verified(token.to_s, purpose: :private_file)
  end

  def verifier
    @verifier ||= ActiveSupport::MessageVerifier.new(
      Rails.application.key_generator.generate_key('private_files'), url_safe: true
    )
  end

  # Bytes of a file we stored. Refuses anything else, so a URL supplied by a
  # client can never make the server fetch an arbitrary address. Pass
  # company_id to also refuse another tenant's file.
  def read(value, company_id: nil)
    if value.to_s.start_with?('data:')
      return Base64.decode64(value.to_s.split(',', 2).last.to_s)
    end

    b, k = locate(value)
    raise Forbidden, 'not a stored file' unless k
    raise Forbidden, "file belongs to another company" if company_id && !owned_by?(value, company_id)

    client.get_object(bucket: b, key: k).body.read
  end

  # Does the key sit under this company's folder?
  def owned_by?(value, company_id)
    _, k = locate(value)
    return false unless k

    parts = k.split('/')
    parts[COMPANY_SEGMENT[parts.first]] == company_id.to_s
  end

  def delete(value)
    b, k = locate(value)
    return false unless k

    client.delete_object(bucket: b, key: k)
    true
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("[PrivateFiles] delete failed for #{k}: #{e.message}")
    false
  end

  def exists?(value)
    b, k = locate(value)
    return false unless k

    client.head_object(bucket: b, key: k)
    true
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    false
  end

  def private?(value)
    locate(value)&.first == ENV['PRIVATE_DOCUMENTS_BUCKET'].presence
  end

  # Copy a legacy object into the private bucket under the same key.
  # @return [String] the new reference
  def copy_to_private(value)
    b, k = locate(value)
    raise Forbidden, 'not a stored file' unless k
    return ref(k, b) if b == bucket

    client.copy_object(bucket: bucket, key: k, copy_source: "#{b}/#{ERB::Util.url_encode(k).gsub('%2F', '/')}",
                       metadata_directive: 'COPY')
    ref(k)
  end

  # Apply `url` to the named keys of each attachment hash, for JSON.
  def presign_attachments(list, *fields, **opts)
    Array(list).map do |att|
      next att unless att.is_a?(Hash)

      att = att.deep_stringify_keys
      fields.each { |f| att[f.to_s] = url(att[f.to_s], **opts) if att[f.to_s].present? }
      att
    end
  end

  # Apply `normalize` to the named keys of each attachment hash, for storage.
  def normalize_attachments(list, *fields)
    Array(list).map do |att|
      next att unless att.is_a?(Hash)

      att = att.to_h.deep_stringify_keys
      fields.each { |f| att[f.to_s] = normalize(att[f.to_s]) if att[f.to_s].present? }
      att
    end
  end

  # Split by hand rather than URI.parse, which rejects the unescaped spaces
  # some stored URLs carry.
  def from_url(value)
    md = value.match(%r{\Ahttps?://([^/?#]+)/([^?#]*)}i) or return nil
    host = md[1].downcase
    path = URI.decode_uri_component(md[2])
    if (m = host.match(/\A(.+)\.s3[.-](?:[a-z0-9-]+\.)?amazonaws\.com\z/))
      [m[1], path]
    elsif host.match?(/\As3[.-](?:[a-z0-9-]+\.)?amazonaws\.com\z/)
      path.split('/', 2)
    end
  end
  private_class_method :from_url
end
