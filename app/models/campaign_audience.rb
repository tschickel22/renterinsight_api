class CampaignAudience < ApplicationRecord
  SOURCE_TYPES = %w[Lead Contact Account].freeze

  belongs_to :campaign

  validates :source_type, inclusion: { in: SOURCE_TYPES }

  # Compute matching records using the workflow ConditionEvaluator.
  # Returns ActiveRecord relation, scoped to the campaign's company.
  def compute_matches
    company = campaign.company
    base = case source_type
           when 'Lead'    then company.leads.where(is_deleted: [false, nil])
           when 'Contact' then company.contacts.where(is_deleted: [false, nil])
           when 'Account' then company.accounts.where(is_deleted: [false, nil])
           end
    # If filter_tree is empty, return all. ConditionEvaluator handles empty tree.
    # NOTE: For Phase A we return base relation; Phase B will add per-record evaluator.
    base
  end
end
