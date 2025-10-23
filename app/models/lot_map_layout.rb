# frozen_string_literal: true

# == Schema Information
#
# Table name: lot_map_layouts
#
#  id                      :integer          not null, primary key
#  company_id              :integer          not null
#  name                    :string           not null
#  address                 :string
#  latitude                :decimal(10, 8)
#  longitude               :decimal(11, 8)
#  boundary                :text             (stored as JSON)
#  lot_count               :integer          default(0)
#  detected_from_satellite :boolean          default(FALSE)
#  industry_type           :string           default("both")
#  created_by              :string
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#

class LotMapLayout < ApplicationRecord
  # Serialize JSON fields for SQLite
  serialize :boundary, coder: JSON

  # Associations
  belongs_to :company
  has_many :lots, class_name: 'LotMapLot', foreign_key: :layout_id, dependent: :destroy

  # Validations
  validates :name, presence: true
  validates :industry_type, inclusion: { in: %w[manufactured_home rv both] }

  # Scopes
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :by_industry, ->(type) { where(industry_type: type) }
  scope :recent, -> { order(created_at: :desc) }

  # Instance Methods
  def coordinates
    return nil unless latitude && longitude
    { lat: latitude.to_f, lng: longitude.to_f }
  end

  def update_lot_count!
    update(lot_count: lots.count)
  end

  def status_metrics
    metrics = lots.group(:status).count
    metrics['total'] = lots.count
    metrics
  end

  # JSON Representation
  def as_json(options = {})
    super(options.merge(
      methods: [:coordinates],
      include: {
        lots: { methods: [] }
      }
    ))
  end
end
