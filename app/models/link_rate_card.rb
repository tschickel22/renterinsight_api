# frozen_string_literal: true

# An installer's prices to one linked dealer (E68 step 6). The installer
# writes and sends it, the dealer approves it once. A changed card is a new
# version; the approved one stays in force until the dealer approves the new
# one, and an approved version never changes, so a job priced from it always
# shows what it was priced on.
class LinkRateCard < ApplicationRecord
  STATUSES = %w[submitted approved declined superseded withdrawn].freeze
  KINDS = %w[base addon].freeze
  UNITS = %w[job section foot each hour].freeze

  belongs_to :company_link
  belongs_to :submitted_by, class_name: 'User', optional: true
  belongs_to :decided_by, class_name: 'User', optional: true

  validates :status, inclusion: { in: STATUSES }
  validate :items_are_priced

  before_validation :tidy_items
  before_update :contents_never_change

  scope :approved, -> { where(status: 'approved') }
  scope :submitted, -> { where(status: 'submitted') }

  def approved? = status == 'approved'
  def submitted? = status == 'submitted'

  def item(key)
    items.find { |i| i['key'] == key.to_s }
  end

  # Prices picked lines from this card: [{ item_key, qty }] in, priced
  # snapshot lines out. Unknown keys and quantities that aren't positive are
  # refused rather than dropped, so a total never quietly leaves something out.
  def price_lines(picks)
    Array(picks).map do |pick|
      pick = pick.to_h.stringify_keys
      found = item(pick['item_key'])
      raise ArgumentError, 'That line is not on their rate card' unless found

      qty = pick['qty'].to_s.to_d
      raise ArgumentError, "Enter a quantity for #{found['name']}" unless qty.positive?

      price = found['price'].to_d
      { 'item_key' => found['key'], 'name' => found['name'], 'unit' => found['unit'],
        'qty' => qty.to_s, 'price' => price.to_s, 'amount' => (price * qty).round(2).to_s }
    end
  end

  private

  def tidy_items
    self.items = Array(items).each_with_index.map do |raw, i|
      it = raw.to_h.deep_stringify_keys
      {
        'key' => it['key'].presence || SecureRandom.hex(4),
        'name' => it['name'].to_s.strip,
        'kind' => KINDS.include?(it['kind']) ? it['kind'] : 'base',
        'unit' => UNITS.include?(it['unit']) ? it['unit'] : 'job',
        'price' => it['price'].to_s.delete(',$').strip.presence,
        'position' => i
      }
    end
  end

  def items_are_priced
    errors.add(:items, 'need at least one line') if items.blank?
    items.each do |it|
      errors.add(:items, 'each need a name') if it['name'].blank?
      price = it['price'].to_s
      errors.add(:items, "#{it['name'].presence || 'A line'} needs a price") unless price.match?(/\A\d+(\.\d{1,2})?\z/)
    end
    errors.add(:items, 'have the same name twice') if items.map { |i| i['name'].downcase }.uniq.size != items.size
  end

  # A version's lines never change once sent: a job priced from it must
  # always show what it was priced on. New prices are a new version.
  def contents_never_change
    return unless (changed & %w[items version note company_link_id]).any?

    errors.add(:base, 'A rate card version cannot change. Send a new version.')
    throw :abort
  end
end
