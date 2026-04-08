module WorkflowEngine
  module StepExecutors
    class AssignOwner < Base
      OWNER_COLS = {
        'Lead' => 'owner_id',
        'Deal' => 'owner_id',
        'Contact' => 'owner_id',
        'Account' => 'account_manager_id'
      }.freeze

      def call
        cfg = @step['config'] || {}
        entity = @run.entity
        entity_type = entity.class.name
        owner_col = OWNER_COLS[entity_type] || 'owner_id'
        unless entity.respond_to?(owner_col) || entity.respond_to?("#{owner_col}=")
          owner_col = 'owner_id' if entity.respond_to?(:owner_id=)
        end
        unless entity.respond_to?("#{owner_col}=")
          return { status: 'skipped', output: { reason: 'no_owner_column' }, next_step_id: next_step_from_edges, wait: nil, error: {} }
        end

        new_owner_id = case cfg['strategy'].to_s
                       when 'specific_user'
                         cfg['user_id']
                       when 'round_robin', 'load_balanced'
                         pool = @run.company.users
                         if cfg['role_filter'].present?
                           begin
                             if pool.first.respond_to?(:roles)
                               pool = pool.joins(:roles).where(roles: { name: cfg['role_filter'] })
                             elsif pool.first.respond_to?(:role)
                               pool = pool.where(role: cfg['role_filter'])
                             end
                           rescue => e
                             Rails.logger.warn "[AssignOwner] role filter failed: #{e.message}"
                           end
                         end
                         pool = @run.company.users if pool.blank?
                         klass = entity.class
                         ranked = pool.to_a.min_by { |u| klass.where(owner_col => u.id).count }
                         ranked&.id
                       end

        if new_owner_id.present?
          entity.update!(owner_col => new_owner_id)
          { status: 'success', output: { owner_id: new_owner_id, column: owner_col }, next_step_id: next_step_from_edges, wait: nil, error: {} }
        else
          { status: 'skipped', output: { reason: 'no_user_selected' }, next_step_id: next_step_from_edges, wait: nil, error: {} }
        end
      rescue => e
        { status: 'skipped', output: { reason: e.message }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end
    end
  end
end
