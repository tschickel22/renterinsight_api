# frozen_string_literal: true

module Api
  module Partner
    module V1
      class ContactsController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :contact

        before_action :authorize_contacts
        before_action :set_contact, only: [:show, :update, :destroy]

        # GET /api/partner/v1/contacts
        def index
          contacts = company_scope(Contact).where(is_deleted: false)

          # Filters
          contacts = contacts.where(account_id: params[:account_id]) if params[:account_id].present?
          contacts = contacts.where(email: params[:email]) if params[:email].present?
          contacts = contacts.where(phone: params[:phone]) if params[:phone].present?
          contacts = contacts.where(owner_id: params[:owner_id]) if params[:owner_id].present?
          contacts = contacts.where(location_id: params[:location_id]) if params[:location_id].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            contacts = contacts.where(
              "first_name ILIKE :q OR last_name ILIKE :q OR email ILIKE :q OR CONCAT(first_name, ' ', last_name) ILIKE :q",
              q: q
            )
          end

          # Cursor-based pagination
          contacts = contacts.order(:id)
          contacts = contacts.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          contacts = contacts.limit(limit + 1)

          records = contacts.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |c| contact_json(c) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/contacts/:id
        def show
          render json: { data: contact_json(@contact, detailed: true) }
        end

        # POST /api/partner/v1/contacts
        def create
          contact = company_scope(Contact).new(contact_params)

          if contact.save
            render json: { data: contact_json(contact, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: contact.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/contacts/:id
        def update
          if @contact.update(contact_params)
            render json: { data: contact_json(@contact, detailed: true) }
          else
            render json: { error: "Validation failed", details: @contact.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/contacts/:id
        def destroy
          @contact.update!(is_deleted: true)
          render json: { data: { id: @contact.id, deleted: true } }
        end

        private

        def authorize_contacts
          case action_name
          when "index", "show"
            authorize_permission!(:contacts, :read)
          when "create"
            authorize_permission!(:contacts, :create)
          when "update"
            authorize_permission!(:contacts, :update)
          when "destroy"
            authorize_permission!(:contacts, :delete)
          end
        end

        def set_contact
          @contact = company_scope(Contact).where(is_deleted: false).find(params[:id])
        end

        def contact_params
          params.permit(*Integration::MappableFields.keys('contacts'))
        end

        def contact_json(contact, detailed: false)
          json = {
            id: contact.id,
            first_name: contact.first_name,
            last_name: contact.last_name,
            email: contact.email,
            phone: contact.phone,
            title: contact.title,
            department: contact.department,
            is_primary: contact.is_primary,
            account_id: contact.account_id,
            owner_id: contact.owner_id,
            location_id: contact.location_id,
            created_at: contact.created_at&.iso8601,
            updated_at: contact.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              company_name: contact.company_name,
              street: contact.street,
              city: contact.city,
              state: contact.state,
              zip: contact.zip,
              country: contact.country,
              opt_out_email: contact.opt_out_email,
              opt_out_sms: contact.opt_out_sms,
              notes: contact.notes
            )
          end

          json
        end
      end
    end
  end
end
