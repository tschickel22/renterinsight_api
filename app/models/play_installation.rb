# frozen_string_literal: true

# A starter play turned on for a company. `answers` is what the dealer chose;
# `assets` holds the ids of every record the play created, so uninstalling
# touches exactly those and nothing a dealer built by hand.
class PlayInstallation < ApplicationRecord
  STATUSES = %w[active uninstalled].freeze

  belongs_to :company
  belongs_to :installed_by, class_name: 'User', foreign_key: 'installed_by_user_id', optional: true

  validates :play_key, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: 'active') }

  before_save :stringify_json

  def asset_ids(kind)
    Array((assets || {})[kind.to_s]).map(&:to_i)
  end

  private

  # JSONB keys must be strings (CLAUDE.md): symbol keys never match on read.
  def stringify_json
    self.answers = (answers || {}).deep_stringify_keys
    self.assets = (assets || {}).deep_stringify_keys
  end
end
