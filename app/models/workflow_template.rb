class WorkflowTemplate < ApplicationRecord
  validates :key, :name, :entity_type, presence: true

  scope :active, -> { where(is_active: true).order(:sort_order, :name) }
  scope :by_category, -> { order(:category, :sort_order, :name) }

  def clone_to_company(company, user:, parameter_overrides: {})
    merged_params = parameters.merge(parameter_overrides.to_h.stringify_keys)
    merged_steps = WorkflowTemplateParameterMerger.merge(steps.deep_dup, merged_params)
    company.workflow_rules.create!(
      name: name,
      description: description,
      entity_type: entity_type,
      status: 'draft',
      trigger: trigger,
      conditions: conditions,
      steps: merged_steps,
      parameters: merged_params,
      workflow_template_id: id,
      is_seeded: true,
      created_by_user_id: user&.id
    )
  end
end
