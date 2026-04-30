class CampaignTemplate < ApplicationRecord
  CATEGORIES = %w[
    b2b_saas_sales mh_buyer_journey rv_buyer_journey re_engagement
    new_arrival_digest post_purchase land_prep factory_order event_followup
  ].freeze
  VERTICALS = %w[manufactured_home rv b2b universal].freeze

  belongs_to :company, optional: true
  belongs_to :created_by, class_name: 'User', foreign_key: :created_by_user_id, optional: true

  validates :slug, :name, :category, :vertical, presence: true
  validates :slug, uniqueness: { scope: :company_id }
  validates :category, inclusion: { in: CATEGORIES }
  validates :vertical, inclusion: { in: VERTICALS }

  scope :seeded, -> { where(is_seeded: true) }
  scope :active, -> { where(is_active: true) }
  scope :for_company_or_seeded, ->(cid) { where('company_id = ? OR is_seeded = true', cid) }
end
