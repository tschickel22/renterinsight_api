# frozen_string_literal: true

# One home a dealer has chosen for a website's Featured Homes section.
#
# title and description are the site's own copy. Blank means "use what the
# inventory record says", so a dealer who never edits them still gets a
# description, and editing them never touches the inventory record.
class WebsiteFeaturedHome < ApplicationRecord
  belongs_to :website
  belongs_to :vehicle

  validates :vehicle_id, uniqueness: { scope: :website_id }
  validate :vehicle_belongs_to_website_company

  scope :ordered, -> { order(:position, :id) }

  ROTATIONS = %w[off visit day week].freeze

  # The site's display settings, cleaned: how many homes to show at a time
  # (nil shows every pick) and how the shown set changes.
  def self.normalize_settings(raw)
    raw = (raw || {}).to_h.stringify_keys
    count = raw['display_count'].presence && raw['display_count'].to_i
    rotation = ROTATIONS.include?(raw['rotation'].to_s) ? raw['rotation'].to_s : 'off'
    { 'display_count' => count && count.clamp(1, 24), 'rotation' => rotation }
  end

  # Which of the picks to show now, in the dealer's order.
  #
  # off:   the first display_count picks.
  # visit: a fresh handful on every page load.
  # day / week: the window steps through the list once a day or once a week,
  #   so every pick gets its turn and a visitor who comes back the same day
  #   sees the same homes.
  def self.rotate(picks, settings, today: Date.current, rng: Random)
    settings = normalize_settings(settings)
    total = picks.size
    count = [settings['display_count'] || total, total].min
    return picks if count >= total

    case settings['rotation']
    when 'visit'
      picks.each_with_index.to_a.sample(count, random: rng).sort_by(&:last).map(&:first)
    when 'day', 'week'
      step = settings['rotation'] == 'day' ? today.jd : today.jd / 7
      start = (step * count) % total
      Array.new(count) { |i| picks[(start + i) % total] }
    else
      picks.first(count)
    end
  end

  def display_title
    title.presence || [vehicle.year, vehicle.make, vehicle.model].compact.join(' ')
  end

  def display_description
    description.presence || vehicle.description
  end

  private

  # A site can only feature its own company's homes.
  def vehicle_belongs_to_website_company
    return if website.nil? || vehicle.nil?
    return if vehicle.company_id == website.company_id

    errors.add(:vehicle, 'is not in this company inventory')
  end
end
