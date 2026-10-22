# frozen_string_literal: true

# A dealer's change to a factory's options, sent to the platform admin
# (backlog E85): a color they added (add; the option is their own dealer
# color), a book color they hid (hide), or their name for an option (rename).
# It works for the dealer the moment they make it. The admin applies it to
# the book for everyone, keeps it for that dealer only, or turns it down (the
# dealer's change is undone and they are told why). Truebuild::DealerOptions
# reads and writes these.
class CatalogOptionRequest < ApplicationRecord
  ACTIONS = %w[add hide rename].freeze
  STATUSES = %w[open applied dealer_only dismissed withdrawn].freeze
  # Statuses under which the change still works for the dealer.
  IN_FORCE = %w[open dealer_only].freeze

  belongs_to :company
  belongs_to :manufacturer
  belongs_to :option, class_name: 'CatalogOption', foreign_key: :catalog_option_id
  belongs_to :deal, optional: true
  belongs_to :requested_by, class_name: 'User', optional: true
  belongs_to :resolved_by, class_name: 'User', optional: true

  validates :action, inclusion: { in: ACTIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :name, presence: true, if: -> { action == 'rename' }

  scope :open, -> { where(status: 'open') }
  scope :in_force, -> { where(status: IN_FORCE) }

  def label
    case action
    when 'add' then "Add #{[color_set, option&.name].compact.join(': ')}"
    when 'hide' then "Remove #{[color_set, option&.name].compact.join(': ')}"
    when 'rename' then "Rename #{option&.name} to #{name}"
    end
  end
end
