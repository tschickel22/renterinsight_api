# frozen_string_literal: true

# A learned decision about one price book option (see the migration). Active
# decisions apply in the buyer's designer ahead of the name rules in code;
# rejected ones are kept so the same suggestion is never made again.
#
#   family        one of a pick-one set named value ("refrigerator")
#   not_family    not pick-one, whatever its name suggests
#   same_finish   a chip shown under the spelling value
#   color_choice  a standard item that is a color the buyer picks, in set value
#   includes      a package that already contains family value, so the two clear each other
class CatalogOptionDecision < ApplicationRecord
  KINDS = %w[family not_family same_finish color_choice includes].freeze
  SOURCES = %w[code claude admin].freeze
  STATUSES = %w[active rejected].freeze

  belongs_to :manufacturer, optional: true
  belongs_to :catalog_price_book, optional: true
  belongs_to :reviewed_by, class_name: 'User', optional: true

  validates :option_key, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :value, presence: true, unless: -> { kind == 'not_family' }

  scope :for_manufacturer, ->(id) { where(manufacturer_id: [id, nil]) }
  scope :active, -> { where(status: 'active') }

  # option key => { kind => value }, a manufacturer's own decision over a platform one.
  def self.applying(manufacturer_id)
    active.for_manufacturer(manufacturer_id).order(Arel.sql('manufacturer_id NULLS FIRST'))
          .each_with_object({}) { |r, h| (h[r.option_key] ||= {})[r.kind] = r.value }
  end

  def self.stamp(manufacturer_id)
    for_manufacturer(manufacturer_id).maximum(:updated_at)
  end

  def reviewed? = reviewed_at.present?
end
