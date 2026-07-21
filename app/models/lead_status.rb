class LeadStatus < ApplicationRecord
  # Tenant-configurable lead statuses. Each company owns its own list; defaults
  # are seeded from the 20260629230000 migration and admins manage the rest via
  # the Lead Statuses tab in CRM settings.
  belongs_to :company

  validates :key, presence: true,
                  uniqueness: { scope: :company_id, case_sensitive: false },
                  format: { with: /\A[a-z0-9_]+\z/, message: 'must be lowercase letters, digits, underscores' }
  validates :label, presence: true
  validate  :label_uniqueness_case_insensitive

  scope :active,   -> { where(is_active: true) }
  scope :excluded, -> { where(is_excluded: true) }
  scope :included, -> { where(is_excluded: false) }
  scope :ordered,  -> { order(:sort_order, :label) }

  before_validation :normalize_key
  before_validation :assign_default_sort_order, on: :create

  private

  def normalize_key
    self.key = key.to_s.strip.downcase.gsub(/[^a-z0-9_]/, '_') if key.present?
  end

  # Default sort_order lands new statuses at the END of the list, matching
  # operator intuition ("I clicked Add, so it should show up at the bottom").
  # Previously the DB default of 0 pushed new rows above every seeded status,
  # confusing dealers who then couldn't find them where they expected. Callers
  # can still pass an explicit sort_order to override this.
  def assign_default_sort_order
    return if sort_order.present? && sort_order.to_i > 0
    return unless company_id
    max = LeadStatus.where(company_id: company_id).maximum(:sort_order).to_i
    self.sort_order = max + 10
  end

  # Prevents "Hot Lead" (key=interested) + "hot lead" (key=hot_lead) both
  # existing under visually-identical labels. Key uniqueness alone doesn't
  # catch this because keys differ. Case-insensitive so "New" and "NEW" also
  # collide.
  def label_uniqueness_case_insensitive
    return unless label.present? && company_id
    scope = LeadStatus.where(company_id: company_id).where('LOWER(label) = ?', label.to_s.strip.downcase)
    scope = scope.where.not(id: id) if persisted?
    if scope.exists?
      errors.add(:label, "already exists for this company (case-insensitive)")
    end
  end
end
