class LeadStatus < ApplicationRecord
  # Tenant-configurable lead statuses. Each company owns its own list; defaults
  # are seeded from the 20260629230000 migration and admins manage the rest via
  # the Lead Statuses tab in CRM settings.
  belongs_to :company

  validates :key, presence: true,
                  uniqueness: { scope: :company_id, case_sensitive: false },
                  format: { with: /\A[a-z0-9_]+\z/, message: 'must be lowercase letters, digits, underscores' }
  validates :label, presence: true

  scope :active,   -> { where(is_active: true) }
  scope :excluded, -> { where(is_excluded: true) }
  scope :included, -> { where(is_excluded: false) }
  scope :ordered,  -> { order(:sort_order, :label) }

  before_validation :normalize_key

  private

  def normalize_key
    self.key = key.to_s.strip.downcase.gsub(/[^a-z0-9_]/, '_') if key.present?
  end
end
