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

  # Where the content came from.
  #
  # 'url'      — crawled a live site (SiteProfiles::Orchestrator)
  # 'manual'   — hand-entered demo for a prospect with no website yet
  # 'document' — an uploaded product sheet or brochure
  #              (SiteProfiles::DocumentOrchestrator)
  #
  # All three produce the same profile contract, which is the whole point: a
  # scanned website and an uploaded spec sheet project into the same layouts.
  SOURCE_KINDS = %w[url manual document].freeze

  # source_url is blank for hand-entered demos and for document uploads — a
  # prospect with no website still needs a shareable preview, and a product
  # sheet has no URL at all.
  validates :source_url, presence: true, unless: -> { entered_manually? || document? }
  validates :status, inclusion: { in: STATUSES }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :document_s3_key, presence: true, if: :document?

  before_create :generate_preview_token

  scope :ready, -> { where(status: 'ready') }
  scope :from_documents, -> { where(source_kind: 'document') }

  def ready?
    status == 'ready'
  end

  def document?
    source_kind == 'document'
  end

  def entered_manually?
    # source_kind is authoritative for rows written since it existed. Older rows
    # predate the column and default to 'url', so the profile payload is still
    # the only way to recognise a hand-entered one.
    source_kind == 'manual' ||
      (profile.is_a?(Hash) && profile.dig('source', 'entered_manually') == true)
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
