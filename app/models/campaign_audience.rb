class CampaignAudience < ApplicationRecord
  SOURCE_TYPES = %w[Lead Contact Account].freeze

  belongs_to :campaign
  belongs_to :saved_audience, class_name: 'Audience', optional: true

  validates :source_type, inclusion: { in: SOURCE_TYPES }

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
