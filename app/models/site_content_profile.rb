# frozen_string_literal: true

# A scanned client site, normalised into template-agnostic content.
#
# This is the durable artifact the whole importer is built around: the expensive,
# fragile part (crawl + extract) happens once and stays reusable — including
# against templates that do not exist yet. Projection into a template is cheap
# and deterministic, so previewing all nine costs nothing.
class SiteContentProfile < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  # Chosen explicitly. Never inferred from `company`, which is only the tenant
  # the admin was switched to when the profile was created.
  belongs_to :inventory_company, class_name: 'Company', optional: true
  has_many :site_profile_projections, dependent: :destroy

  STATUSES = %w[pending fetching extracting ready failed].freeze

  # source_url is blank for hand-entered demos — a prospect with no website
  # still needs a shareable preview.
  validates :source_url, presence: true, unless: :entered_manually?
  validates :status, inclusion: { in: STATUSES }

  before_create :generate_preview_token

  scope :ready, -> { where(status: 'ready') }

  def ready?
    status == 'ready'
  end

  def entered_manually?
    profile.is_a?(Hash) && profile.dig('source', 'entered_manually') == true
  end

  def preview_expired?
    preview_expires_at.present? && preview_expires_at.past?
  end

  def shareable?
    ready? && preview_token.present? && !preview_expired?
  end

  def rotate_preview_token!
    update!(preview_token: self.class.new_preview_token)
  end

  # nil/empty means "all nine".
  def visible_template_ids
    preview_template_ids.presence
  end

  def integrations_by_disposition
    Array(profile['integrations']).group_by { |i| i['disposition'] }
  end

  def warnings
    Array(profile.dig('source', 'warnings')) + Array(report['warnings'])
  end

  def self.new_preview_token
    SecureRandom.urlsafe_base64(24)
  end

  private

  def generate_preview_token
    self.preview_token ||= self.class.new_preview_token
  end
end
