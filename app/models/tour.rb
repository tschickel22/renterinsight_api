# frozen_string_literal: true

class Tour < ApplicationRecord
  TRIGGER_TYPES = %w[manual auto_on_first_visit on_action scheduled].freeze

  # Names older recorder builds and the help widget used for "offer this tour
  # the first time someone opens its page". They all mean auto_on_first_visit.
  TRIGGER_ALIASES = {
    'first_visit'   => 'auto_on_first_visit',
    'auto_on_route' => 'auto_on_first_visit',
    'first_login'   => 'auto_on_first_visit'
  }.freeze

  belongs_to :knowledge_module,
             class_name: 'Knowledge::Module',
             optional: true,
             inverse_of: :tours

  has_many :steps,
           -> { order(:position) },
           class_name: 'TourStep',
           dependent: :destroy,
           inverse_of: :tour

  has_many :completions,
           class_name: 'UserTourCompletion',
           dependent: :destroy,
           inverse_of: :tour

  validates :key,          presence: true, uniqueness: { scope: :knowledge_module_id }
  validates :name,         presence: true
  validates :trigger_type, inclusion: { in: TRIGGER_TYPES }

  before_validation { self.trigger_type = TRIGGER_ALIASES.fetch(trigger_type.to_s, trigger_type) }
  before_validation { self.trigger_route = trigger_route.presence }

  scope :active,  -> { where(is_active: true) }
  # Played and approved by a person; only these reach dealers.
  scope :approved, -> { where.not(approved_at: nil) }
  scope :ordered, -> { order(:position, :name) }

  # The side menu pages the tour walks through: menu links it points at and
  # pages it opens. The app leaves out a tour that runs through a row the
  # company hid from its menu (Company Settings, Customize, Menu), because the
  # tour would stop at a link that is not there.
  def menu_paths
    steps.flat_map { |s| [s.selector.to_s[/data-tour="nav:([^"]+)"/, 1], s.route.to_s.split('?').first.presence] }
         .compact.uniq
  end
end
