module WorkflowEngine
  module StepExecutors
    class AssignOwner < Base
      # Each entity has its own idea of "owner". ServiceTicket stores it as a
      # string (per legacy column), everything else uses a FK integer. The
      # value-normalization at write time (see below) handles the type diff.
      OWNER_COLS = {
        'Lead'          => 'owner_id',
        'Deal'          => 'owner_id',
        'Contact'       => 'owner_id',
        'Account'       => 'account_manager_id',
        'ServiceTicket' => 'assigned_to'
      }.freeze

      # Columns that hold user IDs as strings, not FK integers. Written as
      # `to_s` so DB doesn't reject the value.
      STRING_ID_COLS = %w[assigned_to].freeze

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
                         # Match the column type when counting so ServiceTicket
                         # (assigned_to = string) doesn't return 0 for every user
                         # and pick an arbitrary one.
                         ranked = pool.to_a.min_by do |u|
                           lookup = STRING_ID_COLS.include?(owner_col) ? u.id.to_s : u.id
                           klass.where(owner_col => lookup).count
                         end
                         ranked&.id
                       end

        if new_owner_id.present?
          # ServiceTicket's `assigned_to` is a string column even though it holds
          # a user id — coerce here so we don't crash on a type mismatch.
          value = STRING_ID_COLS.include?(owner_col) ? new_owner_id.to_s : new_owner_id
          entity.update!(owner_col => value)
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
