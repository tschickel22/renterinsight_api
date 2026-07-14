module WorkflowEngine
  module StepExecutors
    class CreateActivity < Base
      MAP = {
        'Lead' => 'LeadActivity',
        'Deal' => 'DealActivity',
        'Contact' => 'ContactActivity',
        'Account' => 'AccountActivity'
      }.freeze

      def call
        config = @step['config'] || {}
        klass_name = MAP[@run.entity_type]
        klass = klass_name&.safe_constantize

        unless klass
          Rails.logger.warn "[CreateActivity] skipped — no activity class for #{@run.entity_type}"
          return { status: 'skipped', output: { reason: 'no_activity_class' }, next_step_id: next_step_from_edges, wait: nil, error: {} }
        end

        assignee_id = resolve_assignee(config['assigned_to_user_id'] || config['assigned_to'])
        # Every activity model has a required `user` (creator) FK on Lead/
        # Contact and an optional one on Deal/Account — set a sensible creator
        # for all four so validations pass either way.
        creator_id = resolve_creator(assignee_id)

        attrs = {
          activity_type: resolve_variables(config['activity_type'].to_s),
          subject: resolve_variables(config['subject'].to_s),
          description: resolve_variables(config['description'].to_s),
          due_date: resolve_due_date(config),
          assigned_to_id: assignee_id,
          user_id: creator_id
        }
        # Optional fields the AI builder emits — passed through only if the
        # column exists, so we don't crash on models missing them.
        %w[status priority].each do |opt|
          next unless config[opt].present? && klass.column_names.include?(opt)
          attrs[opt.to_sym] = resolve_variables(config[opt].to_s)
        end

        attrs[:company_id] = @run.company_id if klass.column_names.include?('company_id')
        assoc_key = "#{@run.entity_type.downcase}_id"
        attrs[assoc_key.to_sym] = @run.entity_id if klass.column_names.include?(assoc_key)

        begin
          created = klass.create!(attrs.compact)
        rescue => e
          Rails.logger.error "[CreateActivity] failed: #{e.message}"
          return { status: 'failed', output: {}, next_step_id: nil, wait: nil, error: { message: e.message } }
        end

        { status: 'success', output: { created: klass_name, id: created.id }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end

      private

      # Assignee resolution:
      # - "owner": use the entity's owner
      # - numeric id or numeric string: use as-is
      # - anything else (name/blank): nil (activity will be unassigned)
      def resolve_assignee(value)
        return nil if value.blank?
        if value.to_s == 'owner'
          return @run.entity.owner_id if @run.entity.respond_to?(:owner_id)
          return default_user_id
        end
        value.to_s =~ /\A\d+\z/ ? value.to_i : nil
      end

      # Creator FK fallback so LeadActivity/ContactActivity (which require a
      # `user`) don't fail with "User must exist" when the workflow runs
      # autonomously. Order: assignee → entity owner → rule author → any
      # admin at the company.
      def resolve_creator(assignee_id)
        assignee_id ||
          (@run.entity.respond_to?(:owner_id) ? @run.entity.owner_id : nil) ||
          @run.workflow_rule&.created_by_user_id ||
          default_user_id
      end

      def default_user_id
        User.where(company_id: @run.company_id, status: 'active').order(:id).limit(1).pick(:id) ||
          User.where(company_id: @run.company_id).order(:id).limit(1).pick(:id)
      end

      # Due date resolution priority:
      #   1. due_date_field: pull from entity's real column OR custom_field_values,
      #      then apply optional due_time (HH:MM). Used by AI when it wants a task
      #      whose date mirrors a lead field like "next_appointment".
      #   2. due_date: literal ISO string (with {{}} resolution) — power users.
      #   3. due_in_days + optional due_time: relative day offset.
      #   4. due_in_hours: relative hour offset (legacy default was 24h).
      def resolve_due_date(config)
        if config['due_date_field'].present?
          base_date = value_from_entity(config['due_date_field'].to_s)
          return combine_date_and_time(base_date, config['due_time']) if base_date.present?
        end

        if config['due_date'].present?
          parsed = safe_parse_time(resolve_variables(config['due_date'].to_s))
          return parsed if parsed
        end

        if config['due_in_days'].present?
          days = config['due_in_days'].to_i
          base = Date.current + days.days
          return combine_date_and_time(base.iso8601, config['due_time'])
        end

        hours = (config['due_in_hours'] || 24).to_i
        Time.current + hours.hours
      end

      # Look up a field on the entity — real column first, then custom fields.
      # Returns a String/Date-ish value or nil.
      def value_from_entity(field)
        entity = @run.entity
        return nil if entity.nil?
        return entity.public_send(field) if entity.respond_to?(field) && entity.class.column_names.include?(field.to_s)

        WorkflowEngine::CustomFieldsAccess.read(entity, field)
      end

      # Merge a "date" and a "HH:MM" into a full timestamp in the app's zone.
      # Accepts date_input as Date, DateTime, ISO string, or nil.
      def combine_date_and_time(date_input, time_str)
        return nil if date_input.blank?

        d = case date_input
            when Date, DateTime, Time then date_input.to_date
            else safe_parse_time(date_input.to_s)&.to_date
            end
        return nil if d.nil?

        hour, minute = parse_hh_mm(time_str)
        Time.zone.local(d.year, d.month, d.day, hour, minute)
      end

      def parse_hh_mm(str)
        m = str.to_s.match(/\A(\d{1,2}):(\d{2})\z/)
        return [9, 0] unless m # sensible business-hours default
        [m[1].to_i, m[2].to_i]
      end

      def safe_parse_time(str)
        Time.zone.parse(str.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
