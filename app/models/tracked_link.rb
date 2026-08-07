# frozen_string_literal: true

class TrackedLink < ApplicationRecord
  belongs_to :company
  belongs_to :communication, optional: true
  belongs_to :entity, polymorphic: true, optional: true
  belongs_to :source, polymorphic: true, optional: true
  belongs_to :vehicle, class_name: 'Vehicle', optional: true
  has_many :tracked_link_events, dependent: :destroy

  before_create :generate_token

  scope :for_entity, ->(type, id) { where(entity_type: type, entity_id: id) }
  scope :with_vehicle, -> { where.not(vehicle_id: nil) }
  scope :for_brochures, -> { where(source_type: 'Brochure') }
  # A brochure link with no vehicle is the collection itself being opened; one
  # with a vehicle is a specific home inside it being clicked.
  scope :brochure_opens,    -> { for_brochures.where(vehicle_id: nil) }
  scope :brochure_listings, -> { for_brochures.where.not(vehicle_id: nil) }
  scope :clicked,      -> { where('click_count > 0') }

  def self.create_for_attachment!(company:, s3_key:, filename:, content_type:, file_size:,
                                  entity_type: nil, entity_id: nil,
                                  source_type: nil, source_id: nil, communication: nil)
    create!(
      company: company,
      s3_key: s3_key,
      filename: filename,
      content_type: content_type,
      file_size: file_size,
      entity_type: entity_type,
      entity_id: entity_id,
      source_type: source_type,
      source_id: source_id,
      communication: communication
    )
  end

  def self.create_for_inventory!(company:, vehicle:, url:,
                                 entity_type: nil, entity_id: nil,
                                 source_type: nil, source_id: nil, communication: nil)
    create!(
      company: company,
      vehicle_id: vehicle.id,
      url: url,
      link_type: 'inventory_view',
      entity_type: entity_type,
      entity_id: entity_id,
      source_type: source_type,
      source_id: source_id,
      communication: communication
    )
  end

  # Wraps a shared brochure's public URL so the click is attributable to the
  # person we sent it to. The brochure's own view_count still increments on the
  # public page, but that counter is anonymous and aggregate — this is what lets
  # the click surface on the recipient's record and in the Workqueue.
  def self.create_for_brochure!(company:, brochure:, url:,
                                entity_type: nil, entity_id: nil, communication: nil)
    create!(
      company: company,
      url: url,
      link_type: 'brochure_view',
      entity_type: entity_type,
      entity_id: entity_id,
      source_type: 'Brochure',
      source_id: brochure.id,
      communication: communication
    )
  end

  # A single home inside a brochure. Reused rather than re-minted per click so
  # click_count accumulates on one row: the same person clicking the same home
  # from the email and again on the brochure page is one home they keep coming
  # back to, which is exactly the signal worth reading.
  def self.for_brochure_listing!(company:, brochure:, vehicle_id:, url:,
                                 entity_type: nil, entity_id: nil)
    existing = where(company_id: company.id, source_type: 'Brochure', source_id: brochure.id,
                     vehicle_id: vehicle_id, entity_type: entity_type, entity_id: entity_id).first
    return existing if existing

    create!(
      company: company,
      vehicle_id: vehicle_id,
      url: url,
      link_type: 'brochure_listing',
      entity_type: entity_type,
      entity_id: entity_id,
      source_type: 'Brochure',
      source_id: brochure.id
    )
  end

  def redirect_url
    if s3_key.present?
      presigned_download_url
    elsif url.present?
      url
    end
  end

  def tracking_url
    "#{Messaging::TrackingUrl.base}/t/#{token}"
  end

  def presigned_download_url(expires_in: 1.hour)
    require 'aws-sdk-s3'
    s3 = Aws::S3::Resource.new(
      region: ENV['AWS_REGION'] || 'us-west-2',
      access_key_id: ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
    )
    bucket = s3.bucket(ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging')
    # Use inline disposition so PDFs/images open in browser; other types download
    disposition = content_type&.start_with?('image/') || content_type == 'application/pdf' ? 'inline' : 'attachment'
    safe_filename = (filename || 'download').gsub('"', '')
    bucket.object(s3_key).presigned_url(
      :get,
      expires_in: expires_in.to_i,
      response_content_disposition: "#{disposition}; filename=\"#{safe_filename}\""
    )
  end

  def record_click!(ip_address: nil, user_agent: nil)
    now = Time.current
    tracked_link_events.create!(clicked_at: now, ip_address: ip_address, user_agent: user_agent)
    update_columns(
      click_count: click_count.to_i + 1,
      last_clicked_at: now,
      first_clicked_at: first_clicked_at || now
    )
  end

  private

  def generate_token
    loop do
      candidate = SecureRandom.urlsafe_base64(16)
      unless self.class.exists?(token: candidate)
        self.token = candidate
        break
      end
    end
  end
end
