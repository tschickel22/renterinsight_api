module WorkflowEngine
  module StepExecutors
    class AddTag < Base
      def call
        cfg = @step['config'] || {}
        tag_names = Array(cfg['tag_names'])
        entity = @run.entity
        added = []
        tag_names.each do |name|
          tag = Tag.for_company(@run.company_id).find_by(name: name) ||
                Tag.create!(name: name, company_id: @run.company_id)
          TagAssignment.find_or_create_by!(
            tag_id: tag.id,
            entity_type: entity.class.name,
            entity_id: entity.id,
            company_id: @run.company_id
          )
          added << name
        end
        { status: 'success', output: { tags_added: added }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      rescue => e
        { status: 'skipped', output: { reason: e.message }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end
    end
  end
end
