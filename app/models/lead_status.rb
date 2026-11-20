class LeadStatus < ApplicationRecord
  # Tenant-configurable lead statuses. Each company owns its own list; defaults
  # are seeded from the 20260629230000 migration and admins manage the rest via
  # the Lead Statuses tab in CRM settings.
  belongs_to :company

  # The default list every company starts with. Copied exactly from
  # db/migrate/20260629230000_create_lead_statuses.rb, which seeded the
  # companies that existed then; ensure_for seeds every company since.
  DEFAULTS = [
    { key: 'new',                   label: 'New',                   sort_order: 10,  is_excluded: false, color: '#3b82f6' },
    { key: 'not_contacted',         label: 'Not Contacted',         sort_order: 20,  is_excluded: false, color: '#64748b' },
    { key: 'attempted_to_contact',  label: 'Attempted to Contact',  sort_order: 30,  is_excluded: false, color: '#f59e0b' },
    { key: 'contact_in_future',     label: 'Contact in Future',     sort_order: 40,  is_excluded: false, color: '#0ea5e9' },
    { key: 'contacted',             label: 'Contacted',             sort_order: 50,  is_excluded: false, color: '#eab308' },
    { key: 'engaged',               label: 'Engaged',               sort_order: 60,  is_excluded: false, color: '#6366f1' },
    { key: 'pre_qualified',         label: 'Pre-Qualified',         sort_order: 70,  is_excluded: false, color: '#14b8a6' },
    { key: 'qualified',             label: 'Qualified',             sort_order: 80,  is_excluded: false, color: '#22c55e' },
    { key: 'showing_scheduled',     label: 'Showing Scheduled',     sort_order: 90,  is_excluded: false, color: '#06b6d4' },
    { key: 'proposal',              label: 'Proposal',              sort_order: 100, is_excluded: false, color: '#a855f7' },
    { key: 'negotiation',           label: 'Negotiation',           sort_order: 110, is_excluded: false, color: '#f97316' },
    { key: 'application_submitted', label: 'Application Submitted', sort_order: 120, is_excluded: false, color: '#8b5cf6' },
    { key: 'closed_won',            label: 'Closed Won',            sort_order: 200, is_excluded: false, color: '#10b981' },
    { key: 'closed_lost',           label: 'Closed Lost',           sort_order: 900, is_excluded: true,  color: '#ef4444' },
    { key: 'lost_lead',             label: 'Lost Lead',             sort_order: 910, is_excluded: true,  color: '#ec4899' },
    { key: 'not_qualified',         label: 'Not Qualified',         sort_order: 920, is_excluded: true,  color: '#94a3b8' },
    { key: 'junk_lead',             label: 'Junk Lead',             sort_order: 930, is_excluded: true,  color: '#78716c' },
  ].freeze

  # Creates whatever the company is missing and returns how many rows it made.
  # Additive only: a key the company already has is never touched, so an
  # admin's label, color or is_excluded change survives. Like the migration,
  # it also adds a row for any status string already on the company's leads
  # that has no matching row, so those leads stay valid.
  #
  # insert_all skips validations, so two guards stand in for them: a default
  # whose label the company already uses under another key is skipped (the
  # label check would refuse it), and ON CONFLICT on (company_id, key) makes a
  # concurrent call harmless.
  def self.ensure_for(company)
    existing = where(company_id: company.id).pluck(:key, :label)
    have_keys   = existing.map { |k, _| k.to_s.downcase }.to_set
    have_labels = existing.map { |_, l| l.to_s.strip.downcase }.to_set
    now = Time.current

    rows = []
    DEFAULTS.each do |s|
      next if have_keys.include?(s[:key])
      next if have_labels.include?(s[:label].downcase)
      rows << seed_row(company.id, now, **s)
      have_keys << s[:key]
      have_labels << s[:label].downcase
    end

    extra_keys = company.leads
                        .where.not(status: [nil, ''])
                        .distinct
                        .pluck(:status)
                        .reject { |k| have_keys.include?(k.to_s.downcase) }
                        .sort
    extra_keys.each_with_index do |key, idx|
      label = key.to_s.humanize
      next if have_labels.include?(label.downcase)
      rows << seed_row(company.id, now, key: key, label: label,
                       sort_order: 500 + idx, # between the active and excluded blocks
                       is_excluded: false)
      have_keys << key.to_s.downcase
      have_labels << label.downcase
    end

    return 0 if rows.empty?
    insert_all(rows, unique_by: %i[company_id key]).rows.length
  end

  # Every row in one insert_all must carry the same columns.
  def self.seed_row(company_id, now, key:, label:, sort_order:, is_excluded:, color: nil)
    { company_id: company_id, key: key, label: label, color: color,
      sort_order: sort_order, is_active: true, is_excluded: is_excluded,
      created_at: now, updated_at: now }
  end
  private_class_method :seed_row

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
