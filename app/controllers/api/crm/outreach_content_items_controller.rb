# frozen_string_literal: true

module Api
  module Crm
    # The videos and links Proactive Outreach may send (backlog E105).
    class OutreachContentItemsController < ApplicationController
      before_action :set_company_scope
      before_action :set_item, only: %i[update destroy]

      def self.item_json(item)
        item.as_json(only: %i[id title url topic use_when description source_kind status approved_at])
      end

      def create
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!

        item = @company.outreach_content_items.build(item_params)
        item.source_kind = params.dig(:item, :source_kind) == 'training_video' ? 'training_video' : 'manual'
        # Adding it by hand is the approval.
        item.status = 'approved'
        item.approved_by_user_id = current_user.id
        item.approved_at = Time.current
        return render(json: { error: item.errors.full_messages.to_sentence }, status: :unprocessable_entity) unless item.save

        render json: { item: self.class.item_json(item) }, status: :created
      end

      def update
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!
        return if performed?

        @item.assign_attributes(item_params)
        status = params.dig(:item, :status).to_s
        if status == 'approved' && @item.status != 'approved'
          @item.assign_attributes(status: 'approved', approved_by_user_id: current_user.id, approved_at: Time.current)
        elsif %w[pending archived].include?(status)
          @item.status = status
        end
        return render(json: { error: @item.errors.full_messages.to_sentence }, status: :unprocessable_entity) unless @item.save

        render json: { item: self.class.item_json(@item) }
      end

      def destroy
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!
        return if performed?

        @item.destroy!
        head :no_content
      end

      def import_from_campaigns
        return unless authorize_action!('company_settings', 'update')
        return unless outreach_allowed!

        result = Outreach::CampaignContentImport.call(@company)
        render json: { found: result.found, added: result.added }
      end

      private

      def outreach_allowed!
        return true if Outreach::Settings.for(@company).add_on?

        render json: { error: 'Proactive Outreach is not part of this subscription' }, status: :forbidden
        false
      end

      def set_item
        @item = @company.outreach_content_items.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def item_params
        params.require(:item).permit(:title, :url, :topic, :use_when, :description)
      end
    end
  end
end
