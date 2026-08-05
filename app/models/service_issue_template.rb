# frozen_string_literal: true

# A reusable canned complaint -- "Shingle repair", "Cracks in ceiling",
# "Front door stuck", "Formica popping on island". Effectively an op code:
# picking one drops a pre-filled issue onto a ticket, optionally carrying the
# labor allowance and parts that usually accompany it.
class ServiceIssueTemplate < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true

  attribute :default_parts, :json, default: []

  CATEGORIES = %w[general exterior interior roofing plumbing electrical hvac
                  appliance structural cosmetic setup].freeze

  validates :title, presence: true
  validates :category, presence: true
  validates :default_pay_type, presence: true,
                               inclusion: { in: ServiceTicketIssue::PAY_TYPES }
  validates :title, uniqueness: { scope: :company_id, case_sensitive: false, conditions: -> { where(is_active: true) } }

  scope :active, -> { where(is_active: true) }
  scope :ordered, -> { order(:position, :title) }
  scope :for_category, ->(category) { where(category: category) }
  scope :for_location, lambda { |location_id|
    location_id.present? ? where(location_id: [location_id, nil]) : all
  }

  before_validation :set_position, on: :create

  # Attributes for building a ServiceTicketIssue from this template. Amounts
  # land in the *estimate* fields: a template's numbers are a starting point,
  # not what was actually used.
  def to_issue_attrs
    {
      title: title,
      complaint: complaint,
      correction: correction,
      pay_type: default_pay_type,
      labor: default_labor_rows,
      parts: default_part_rows,
      # A template carrying default hours/rate/parts arrives with an estimate
      # already on it, so it must not read as "not priced" while showing an
      # amount. Templates with no numbers still start unpriced.
      pricing_status: seeds_amounts? ? 'estimated' : 'unpriced'
    }
  end

  # True when applying this template puts a usable amount on the issue.
  def seeds_amounts?
    return true if default_hours.present? && default_rate.present?

    parts = default_parts.is_a?(Array) ? default_parts : []
    parts.any? do |row|
      (row['quantity'] || row['estQuantity']).present? &&
        (row['unitCost'] || row['estUnitCost']).present?
    end
  end

  private

  def default_labor_rows
    return [] if default_hours.blank? && default_rate.blank?

    [{
      'id' => SecureRandom.uuid,
      'description' => title,
      'estHours' => default_hours&.to_f,
      'estRate' => default_rate&.to_f,
      'actHours' => nil,
      'actRate' => nil,
      'addedBy' => 'dealer',
      'confirmedAt' => nil
    }]
  end

  def default_part_rows
    rows = default_parts.is_a?(Array) ? default_parts : []

    rows.map do |row|
      {
        'id' => SecureRandom.uuid,
        'partNumber' => row['partNumber'] || row['part_number'],
        'description' => row['description'],
        'partId' => row['partId'] || row['part_id'],
        'estQuantity' => row['quantity']&.to_f || row['estQuantity']&.to_f,
        'estUnitCost' => row['unitCost']&.to_f || row['estUnitCost']&.to_f,
        'actQuantity' => nil,
        'actUnitCost' => nil,
        'addedBy' => 'dealer',
        'confirmedAt' => nil
      }
    end
  end

  def set_position
    return if position.present? && position.positive?

    self.position = (company&.service_issue_templates&.active&.maximum(:position) || -1) + 1
  end
end
