# frozen_string_literal: true

class QuickbooksEntityMapping < ApplicationRecord
  belongs_to :company

  validates :entity_type, :ri_entity_id, :qb_entity_type, :qb_entity_id, presence: true

  scope :for_company, ->(company_id) { where(company_id: company_id) }

  def self.qb_id_for(company_id, entity_type, ri_entity_id)
    where(company_id: company_id, entity_type: entity_type, ri_entity_id: ri_entity_id).first&.qb_entity_id
  end

  def self.record_sync(company_id, entity_type, ri_entity_id, qb_entity_type, qb_entity_id)
    mapping = where(company_id: company_id, entity_type: entity_type, ri_entity_id: ri_entity_id).first_or_initialize
    mapping.update!(
      qb_entity_type: qb_entity_type,
      qb_entity_id: qb_entity_id,
      last_synced_at: Time.current,
      sync_status: 'synced',
      error_message: nil
    )
    mapping
  end

  def self.record_error(company_id, entity_type, ri_entity_id, error_message)
    mapping = where(company_id: company_id, entity_type: entity_type, ri_entity_id: ri_entity_id).first_or_initialize
    mapping.update(sync_status: 'error', error_message: error_message.to_s.truncate(500))
    mapping
  end
end
