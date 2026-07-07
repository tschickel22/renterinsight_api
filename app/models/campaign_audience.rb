class CampaignAudience < ApplicationRecord
  SOURCE_TYPES = %w[Lead Contact Account].freeze

  belongs_to :campaign
  belongs_to :saved_audience, class_name: 'Audience', optional: true

  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validate  :additional_source_types_valid

  # Enroller fans out across this list in addition to source_type, so the
  # same tag-filtered audience can pull both Leads and Contacts (or any
  # combination). Nil / empty preserves the original single-source
  # behavior. Same allowlist as SOURCE_TYPES; dedupe against source_type
  # so a caller can't send an entry that duplicates the primary type.
  def all_source_types
    ([source_type] + Array(additional_source_types)).uniq.compact
  end

  private

  def additional_source_types_valid
    return if additional_source_types.blank?
    unless additional_source_types.is_a?(Array)
      errors.add(:additional_source_types, 'must be an array')
      return
    end
    invalid = additional_source_types.reject { |t| SOURCE_TYPES.include?(t.to_s) }
    errors.add(:additional_source_types, "contains unsupported types: #{invalid.join(', ')}") if invalid.any?
  end

  public

  # Returns a base relation for the campaign's company.
  # For SMS campaigns, automatically scopes to opted-in recipients UNLESS
  # the audience metadata has compliance_override_acknowledged='true'.
  def compute_matches
    company = campaign.company
    base = case source_type
           when 'Lead'    then company.leads
           when 'Contact' then company.contacts.where(is_deleted: [false, nil])
           when 'Account' then company.accounts.where(is_deleted: [false, nil])
           end
    base = scope_for_sms_compliance(base) if campaign.sms_channel?
    base
  end

  def sms_compliance_override?
    metadata.is_a?(Hash) && metadata['compliance_override_acknowledged'].to_s == 'true'
  end

  private

  # Apply opt-in filter unless explicitly overridden.
  # Source type Account doesn't have an opt-in field; SMS to Accounts is not supported.
  def scope_for_sms_compliance(base)
    return base if sms_compliance_override?
    return base.none if source_type == 'Account'

    column = nil
    if base.klass.column_names.include?('opt_in_sms')
      column = :opt_in_sms
    elsif base.klass.column_names.include?('sms_opt_in')
      column = :sms_opt_in
    end
    return base unless column

    base.where(column => true)
  end
end
