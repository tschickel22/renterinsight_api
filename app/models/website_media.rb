class WebsiteMedia < ApplicationRecord
  # Associations
  belongs_to :company
  # Optional: a site import copies imagery onto S3 before any Website exists,
  # and those rows still need to be tracked. The column has always been
  # nullable; only the association was stricter than the schema.
  belongs_to :website, optional: true
  
  # Enums - Rails 8 syntax
  enum :file_type, { image: 0, video: 1, document: 2, other: 3 }, default: :other
  
  # Validations
  validates :name, presence: true
  validates :url, presence: true
  validates :file_size, presence: true, numericality: { greater_than: 0 }
  
  # What an upload of each kind is allowed to weigh.
  #
  # One number could not serve both: a dealer's walkthrough shot on a phone is
  # routinely over 100MB, while a hero image that size is a mistake nobody wants
  # sent to a buyer on cellular. Enforced here as well as in the browser, because
  # the browser check is a courtesy and this one is the rule , before the change
  # there was no server-side ceiling at all, and an oversized upload spent the
  # whole request buffering itself into memory before failing on something else.
  MAX_UPLOAD_BYTES = {
    'image' => 25.megabytes,
    'video' => 200.megabytes,
    'document' => 50.megabytes,
    'other' => 50.megabytes
  }.freeze

  def self.kind_for(mime_type)
    return 'image' if mime_type&.start_with?('image/')
    return 'video' if mime_type&.start_with?('video/')
    return 'document' if mime_type&.start_with?('application/pdf')

    'other'
  end

  def self.max_upload_bytes(mime_type)
    MAX_UPLOAD_BYTES.fetch(kind_for(mime_type), MAX_UPLOAD_BYTES['other'])
  end

  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :images, -> { where(file_type: :image) }
  scope :videos, -> { where(file_type: :video) }
  scope :documents, -> { where(file_type: :document) }
  
  # URL helpers
  #
  # Permanent and public, never presigned: the bucket policy already makes
  # objects readable, and a presigned URL written into a header/footer config or
  # a page's blocks expires while the page is still live.
  #
  # CDN first when CDN_DOMAIN is set. The old order could never reach the CDN
  # branch , every upload writes both url and s3_key, so the first two arms
  # always matched , which is why pointing CDN_DOMAIN at a distribution changed
  # nothing. Derived from the key rather than from the stored url, so assets
  # uploaded before the distribution existed are served through it too. The
  # bucket stays public either way, so any URL already published keeps working.
  #
  # Only for objects in the bucket the distribution actually fronts. A
  # distribution has exactly one origin, while rows here can name several
  # buckets , s3_bucket is stored per row, and CATALOG_ASSETS_BUCKET exists
  # precisely so catalog imagery does NOT share the uploads bucket. Rewriting
  # one of those onto the CDN host would produce a confident 404 in place of a
  # URL that works today.
  def full_url
    key = s3_key.presence || s3_key_from_url

    if cdn_host && key.present? && bucket_name == cdn_bucket
      "https://#{cdn_host}/#{key}"
    elsif url.present? && url.start_with?('http')
      url
    elsif s3_key.present?
      # Build permanent public URL from s3_key
      region = ENV['AWS_REGION'] || 'us-west-2'
      "https://#{bucket_name}.s3.#{region}.amazonaws.com/#{s3_key}"
    elsif cdn_host
      "https://#{cdn_host}/#{url}"
    else
      url
    end
  end

  # Generate a temporary presigned URL (use only when private access is needed)
  def presigned_url(expires_in: 3600)
    return nil unless s3_key.present?
    s3_service = S3UploadService.new
    s3_service.presigned_url(s3_key, expires_in: expires_in)
  end

  private

  DEFAULT_BUCKET = 'renterinsight-website-assets-staging'

  # The hostname of the distribution, with any scheme or trailing slash a human
  # pasted into the env var taken back off. The URL is built by interpolation,
  # so "https://cdn.example.com/" would otherwise produce
  # "https://https://cdn.example.com//key".
  def cdn_host
    ENV['CDN_DOMAIN'].presence&.sub(%r{\Ahttps?://}, '')&.delete_suffix('/').presence
  end

  # Which bucket the distribution is in front of. Defaults to the uploads
  # bucket, since that is what Option A put behind CloudFront; set CDN_BUCKET
  # only if the distribution is ever pointed somewhere else.
  def cdn_bucket
    ENV['CDN_BUCKET'].presence || ENV['AWS_S3_BUCKET'].presence || DEFAULT_BUCKET
  end

  # Which bucket THIS object is in. Stored per row since the catalog archiver
  # started writing elsewhere; older rows carry it in the URL, and older ones
  # still predate both and are in the default bucket by construction.
  def bucket_name
    s3_bucket.presence || bucket_from_url || ENV['AWS_S3_BUCKET'].presence || DEFAULT_BUCKET
  end

  def bucket_from_url
    host = s3_uri&.host
    return nil if host.blank?

    # bucket.s3.region.amazonaws.com and bucket.s3.amazonaws.com both start with
    # the bucket name; the path-style s3.region.amazonaws.com/bucket/key does not.
    return host.split('.s3.').first if host.include?('.s3.')

    nil
  end

  # The object key inside a stored absolute S3 URL.
  #
  # Rows written before s3_key existed carry only the URL, and a CloudFront
  # distribution in front of the same bucket answers on exactly that path.
  # Only our own buckets are unpacked; a URL pointing anywhere else is left
  # alone, since rewriting it onto our CDN host would produce a 404.
  def s3_key_from_url
    s3_uri&.path&.delete_prefix('/').presence
  end

  # The stored URL, parsed, but only when it points at S3. Anything else , a
  # Pexels stock photo copied in by a site scan, a dealer's own CDN , is not
  # ours to take apart.
  def s3_uri
    return nil if url.blank? || !url.start_with?('http')

    uri = URI.parse(url)
    return nil unless uri.host.to_s.include?('.s3.') || uri.host.to_s.end_with?('.amazonaws.com')

    uri
  rescue URI::InvalidURIError
    nil
  end
end
