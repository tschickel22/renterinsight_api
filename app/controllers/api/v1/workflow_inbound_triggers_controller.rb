module Api
  module V1
    class WorkflowInboundTriggersController < ApplicationController
      include RbacAuthorization
      include ModuleAccessRequired
      before_action :set_company_scope
      require_module! 'management.workflows'
      before_action :set_trigger, only: [:show, :update, :destroy]

      rbac_resource :workflow_automation,
                    read_actions: [:index, :show],
                    create_actions: [:create],
                    update_actions: [:update],
                    delete_actions: [:destroy]

      def index
        items = @company.workflow_inbound_triggers.order(created_at: :desc)
        render json: items.map { |t| serialize(t) }
      end

      def show
        render json: serialize(@trigger)
      end

      def create
        t = @company.workflow_inbound_triggers.new(trigger_params)
        t.token ||= SecureRandom.hex(16)
        t.active = true if t.active.nil?
        if t.save
          render json: serialize(t), status: :created
        else
          render json: { errors: t.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @trigger.update(trigger_params)
          render json: serialize(@trigger)
        else
          render json: { errors: @trigger.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @trigger.destroy
        head :no_content
      end

      private

      def set_trigger
        @trigger = @company.workflow_inbound_triggers.find(params[:id])
      end

      def trigger_params
        params.require(:workflow_inbound_trigger).permit(:name, :workflow_rule_id, :active)
      end

      def serialize(t)
        {
          id: t.id,
          name: t.name,
          token: t.token,
          workflow_rule_id: t.workflow_rule_id,
          active: t.active,
          last_triggered_at: t.last_triggered_at,
          created_at: t.created_at
        }
      end
    end
  end
end
