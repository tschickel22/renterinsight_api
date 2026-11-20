# frozen_string_literal: true

# One group of leads Proactive Outreach works (backlog E105).
class OutreachWave < ApplicationRecord
  STATUSES = %w[building audience_ready drafting review running paused completed failed].freeze
  MAX_SIZE = 100
  MAX_DAILY = 50
  # email, text, or both. With both, first_channel opens and they take turns after.
  CHANNELS = %w[email text both].freeze
  FIRST_CHANNELS = %w[email text].freeze

  belongs_to :company
  has_many :outreach_targets, foreign_key: :outreach_wave_id, inverse_of: :outreach_wave, dependent: :destroy
  has_many :outreach_events, foreign_key: :outreach_wave_id, inverse_of: :outreach_wave, dependent: :destroy

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :target_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_SIZE }
  validates :daily_limit, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_DAILY }
  validates :channels, inclusion: { in: CHANNELS }
  validates :first_channel, inclusion: { in: FIRST_CHANNELS }

  def contacted
    outreach_targets.where(test_group: 'contact')
  end

  def held_back
    outreach_targets.where(test_group: 'holdout')
  end

  def allows?(channel)
    channels == 'both' || channels == channel.to_s
  end

  # The channel the first message goes by for someone this reachable, or nil
  # when this wave cannot reach them. reach is an Outreach::Eligibility::Reach.
  def opening_channel(reach)
    order = first_channel == 'text' ? %w[text email] : %w[email text]
    order.select { |channel| allows?(channel) }.find { |channel| reach.public_send(channel) }
  end

  # The next follow-up's channel: the other one when both are allowed and work.
  def next_channel(reach, last:)
    usable = %w[email text].select { |channel| allows?(channel) && reach.public_send(channel) }
    return usable.first if usable.size < 2

    last.to_s == 'text' ? 'email' : 'text'
  end

  def channels_label
    case channels
    when 'email' then 'Email only'
    when 'text' then 'Text only'
    else first_channel == 'text' ? 'Text and email, text first' : 'Email and text, email first'
    end
  end
end
