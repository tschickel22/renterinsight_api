module WorkflowEngine
  module StepExecutors
    class RemoveTag < Base
      def call
        cfg = @step['config'] || {}
        tag_names = Array(cfg['tag_names'])
        entity = @run.entity
        removed = []
        tag_names.each do |name|
          tag = Tag.for_company(@run.company_id).find_by(name: name)
          next unless tag
          count = TagAssignment.where(
            tag_id: tag.id,
            entity_type: entity.class.name,
            entity_id: entity.id
          ).delete_all
          removed << name if count > 0
        end
        { status: 'success', output: { tags_removed: removed }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      rescue => e
        { status: 'skipped', output: { reason: e.message }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end
    end
  end
end
