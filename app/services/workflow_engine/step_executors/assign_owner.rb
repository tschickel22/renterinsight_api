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

      # Trailing window for load_balanced. "Current workload", not career total.
      LOAD_WINDOW = 30.days

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
                       when 'round_robin_list'
                         # True cursor-based round-robin using a shared
                         # RoundRobinAssignmentList — same rotation that
                         # inbound webhook api keys use, so tokens and
                         # workflows draw from one ordered list and one
                         # cursor. Skips inactive users automatically.
                         list_id = cfg['round_robin_list_id']
                         list = RoundRobinAssignmentList.active.find_by(id: list_id, company_id: @run.company_id)
                         list&.next_active_user!&.id
                       when 'round_robin', 'load_balanced'
                         pool = eligible_pool(cfg, entity)
                         return skipped('no_eligible_users') if pool.empty?

                         klass = entity.class
                         strategy = cfg['strategy'].to_s

                         # Both strategies rank by a per-user key and take the
                         # minimum; only the key differs.
                         #
                         #   round_robin   -> least-recently-assigned. The user
                         #     whose newest record is oldest goes next, so
                         #     assigning to someone pushes them to the back of
                         #     the line. That is a real rotation, and unlike a
                         #     stored cursor it self-corrects when the roster
                         #     changes. Users with nothing yet sort first.
                         #
                         #   load_balanced -> fewest records in the trailing
                         #     window. Counting lifetime records (the previous
                         #     behavior for BOTH strategies) meant a veteran's
                         #     count could never come back down, so the pick
                         #     converged permanently on the newest hire.
                         ranked = pool.min_by do |u|
                           lookup = STRING_ID_COLS.include?(owner_col) ? u.id.to_s : u.id
                           owned = klass.where(owner_col => lookup)
                           owned = owned.where(company_id: @run.company_id) if klass.column_names.include?('company_id')
                           owned = owned.where(is_deleted: [false, nil]) if klass.column_names.include?('is_deleted')

                           if strategy == 'round_robin'
                             [owned.maximum(:created_at)&.to_f || 0.0, u.id]
                           else
                             [owned.where(created_at: LOAD_WINDOW.ago..).count, u.id]
                           end
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

      private

      def skipped(reason)
        { status: 'skipped', output: { reason: reason }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end

      # Who is actually allowed to receive this record.
      #
      # Every filter here was previously missing: the pool was the raw
      # `company.users`, so deactivated users and reps at other locations were
      # assignable, and a role_filter that matched nobody silently fell back to
      # "anyone in the company" rather than assigning no one.
      def eligible_pool(cfg, entity)
        pool = @run.company.users
        pool = pool.where(status: 'active') if User.column_names.include?('status')

        if cfg['role_filter'].present?
          filtered = apply_role_filter(pool, cfg['role_filter'])
          # An unmatched role filter means the rule is misconfigured (renamed or
          # typo'd role). Assigning to the whole company is a worse outcome than
          # leaving the record unassigned for a human to catch, so honor the
          # filter even when it empties the pool.
          if filtered.nil?
            Rails.logger.warn "[AssignOwner] role filter '#{cfg['role_filter']}' could not be applied; leaving unassigned"
            return []
          end
          pool = filtered
        end

        pool = scope_to_entity_location(pool, entity)
        pool.to_a
      end

      # A "role" is either an RBAC Role record or the legacy users.role string,
      # depending on whether the tenant has RBAC on. Match against BOTH and union
      # the result — checking only the association (the previous behavior) meant
      # the filter silently matched nobody for every RBAC-off tenant.
      #
      # Returns nil only if neither representation is queryable, which is what
      # tells the caller to leave the record unassigned.
      def apply_role_filter(pool, role_filter)
        matched_ids = []

        if User.reflect_on_association(:roles)
          matched_ids |= pool.joins(:roles).where(roles: { name: role_filter }).pluck(:id)
        end

        if User.column_names.include?('role')
          matched_ids |= pool.where(role: role_filter).pluck(:id)
        end

        pool.where(id: matched_ids)
      rescue => e
        Rails.logger.warn "[AssignOwner] role filter failed: #{e.message}"
        nil
      end

      # Don't hand a Panama City lead to a rep who only works Carencro. There is
      # no users.location_id column — location membership lives in
      # user_role_assignments, so reuse User#accessible_locations (company-tier
      # and admin users legitimately match every location).
      #
      # If nobody in the pool covers the record's location the filter is dropped
      # rather than assigning to no one: an unassigned lead is invisible, and a
      # cross-location assignment is at least actionable. Logged either way.
      def scope_to_entity_location(pool, entity)
        location_id = entity.try(:location_id)
        return pool if location_id.blank?

        scoped = pool.select { |u| u.accessible_locations.exists?(id: location_id) }
        return scoped if scoped.any?

        Rails.logger.warn "[AssignOwner] no pool user covers location #{location_id}; assigning without location filter"
        pool
      rescue => e
        Rails.logger.warn "[AssignOwner] location scoping failed: #{e.message}"
        pool
      end
    end
  end
end
