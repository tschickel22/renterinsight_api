module WorkflowEngine
  module StepExecutors
    class UpdateField < Base
      BLACKLIST = %w[id company_id created_at updated_at].freeze

      def call
        config = @step['config'] || {}
        fields = config['fields'] || {}

        filtered = fields.reject do |k, _v|
          k_s = k.to_s
          BLACKLIST.include?(k_s) || k_s.end_with?('_id')
        end

        resolved = filtered.transform_values do |v|
          v.is_a?(String) ? resolve_variables(v) : v
        end

        # Split into real AR attributes vs custom_field_values so a rule that
        # sets `next_appointment` on a Lead (a custom field on Evangeline) doesn't
        # crash with `unknown attribute 'next_appointment' for Lead`.
        partitioned = CustomFieldsAccess.partition(@run.entity, resolved)

        Rails.logger.info "[UpdateField] run=#{@run.id} step=#{@step['id']} real=#{partitioned[:real].keys} custom=#{partitioned[:custom].keys}"

        begin
          @run.entity.update!(partitioned[:real]) if partitioned[:real].any?
          CustomFieldsAccess.write(@run.entity, partitioned[:custom]) if partitioned[:custom].any?
        rescue => e
          Rails.logger.error "[UpdateField] failed: #{e.message}"
          return { status: 'failed', output: {}, next_step_id: nil, wait: nil, error: { message: e.message } }
        end

        { status: 'success', output: { updated: resolved }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end
    end
  end
end
