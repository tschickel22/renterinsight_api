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

        due_in_hours = (config['due_in_hours'] || 24).to_i
        attrs = {
          activity_type: resolve_variables(config['activity_type'].to_s),
          subject: resolve_variables(config['subject'].to_s),
          description: resolve_variables(config['description'].to_s),
          due_date: Time.current + due_in_hours.hours,
          assigned_to_id: resolve_assignee(config['assigned_to'])
        }
        attrs[:company_id] = @run.company_id if klass.column_names.include?('company_id')
        assoc_key = "#{@run.entity_type.downcase}_id"
        attrs[assoc_key.to_sym] = @run.entity_id if klass.column_names.include?(assoc_key)

        begin
          klass.create!(attrs.compact)
        rescue => e
          Rails.logger.error "[CreateActivity] failed: #{e.message}"
          return { status: 'failed', output: {}, next_step_id: nil, wait: nil, error: { message: e.message } }
        end

        { status: 'success', output: { created: klass_name }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end

      private

      def resolve_assignee(value)
        if value == 'owner'
          return @run.entity.owner_id if @run.entity.respond_to?(:owner_id)
          return Current.user&.id if defined?(Current) && Current.respond_to?(:user)
          admin = User.where(company_id: @run.company_id).find { |u| u.respond_to?(:admin?) && u.admin? }
          return admin&.id || User.where(company_id: @run.company_id).first&.id
        end
        value
      end
    end
  end
end
