# frozen_string_literal: true

module Api
  module V1
    # The client's side of their onboarding list (backlog E97), shown in
    # Getting started. Every user of the company sees it and can finish an
    # item, reopen one, add a note or a file; only DealerTide adds, edits or
    # removes items (Api::Admin::OnboardingController).
    class OnboardingController < ApplicationController
      before_action :set_company_scope
      before_action :set_item, except: :index

      # GET /api/v1/onboarding
      def index
        render json: { items: Onboarding::View.items(@company), progress: Onboarding::View.progress(@company),
                       events: Onboarding::View.events(@company, limit: 15) }
      end

      # POST /api/v1/onboarding/items/:id/done { note }
      # Needs a note or a file on the item first; note here counts.
      def done
        respond { checklist.complete!(@item, note: params[:note]) }
      end

      # POST /api/v1/onboarding/items/:id/reopen
      def reopen
        respond { checklist.reopen!(@item, note: params[:note]) }
      end

      # POST /api/v1/onboarding/items/:id/note { body }
      def note
        respond { checklist.note!(@item, params[:body]) }
      end

      # POST /api/v1/onboarding/items/:id/files  (multipart: file)
      def upload
        respond { checklist.upload!(@item, params[:file]) }
      end

      # GET /api/v1/onboarding/items/:id/files/:file_id
      def download
        file = @item.files.find_by(id: params[:file_id])
        return render(json: { error: 'Not found' }, status: :not_found) unless file

        # A short-lived link, asked for with the person's sign-in; a plain link
        # in the browser would not carry it.
        render json: { url: file.blob.url(expires_in: 5.minutes, disposition: 'attachment'), name: file.filename.to_s }
      end

      private

      def set_item
        @item = @company.onboarding_items.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def checklist = Onboarding::Checklist.new(@company, actor: current_user, side: 'client')

      def respond
        item = yield
        render json: { item: Onboarding::View.item(item.reload), progress: Onboarding::View.progress(@company) }
      rescue Onboarding::Checklist::Invalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end
    end
  end
end
