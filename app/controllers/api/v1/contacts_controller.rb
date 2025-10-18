# frozen_string_literal: true

module Api
  module V1
    class ContactsController < ApplicationController
      before_action :set_contact, only: [:show, :update, :destroy, :add_tags, :remove_tag, :opt_in_email, :opt_out_email, :opt_in_sms, :opt_out_sms, :deals, :quotes]
      before_action :set_account, only: [:index]

      # GET /api/v1/contacts
      # GET /api/v1/accounts/:account_id/contacts
      def index
        @contacts = if @account
                      @account.contacts
                    else
                      Contact.all
                    end

        # Apply filters
        @contacts = apply_filters(@contacts)

        # Apply search
        @contacts = @contacts.search(params[:search]) if params[:search].present?

        # Apply sorting
        @contacts = apply_sorting(@contacts)

        # Pagination
        page = params[:page]&.to_i || 1
        per_page = params[:per_page]&.to_i || 50
        per_page = [per_page, 100].min # Cap at 100
        
        total_count = @contacts.count
        total_pages = (total_count.to_f / per_page).ceil
        offset = (page - 1) * per_page
        
        @contacts = @contacts.limit(per_page).offset(offset)

        render json: {
          contacts: @contacts.map { |contact| contact_json(contact) },
          meta: {
            current_page: page,
            total_pages: total_pages,
            total_count: total_count,
            per_page: per_page
          }
        }
      rescue => e
        Rails.logger.error "Error in contacts#index: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/contacts/stats
      def stats
        render json: Contact.statistics
      rescue => e
        Rails.logger.error "Error in contacts#stats: #{e.message}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/contacts/:id
      def show
        render json: contact_json(@contact, detailed: true)
      end

      # POST /api/v1/contacts
      def create
        # Extract tags from the contact params before creating
        tag_names = contact_params_with_extra[:tags] || []
        
        @contact = Contact.new(contact_params)

        if @contact.save
          # Handle tags if provided
          handle_tags(@contact, tag_names) if tag_names.is_a?(Array) && tag_names.any?

          render json: contact_json(@contact, detailed: true), status: :created
        else
          render json: { errors: @contact.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error in contacts#create: #{e.message}\n#{e.backtrace.join("\n")}"
        Rails.logger.error "Params: #{params.inspect}"
        render json: { error: e.message, details: e.backtrace.first(5) }, status: :internal_server_error
      end

      # PATCH/PUT /api/v1/contacts/:id
      def update
        # Extract tags from the contact params before updating
        tag_names = contact_params_with_extra[:tags]
        
        if @contact.update(contact_params)
          # Handle tags if provided
          handle_tags(@contact, tag_names) if tag_names

          render json: contact_json(@contact, detailed: true)
        else
          render json: { errors: @contact.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error in contacts#update: #{e.message}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # DELETE /api/v1/contacts/:id
      def destroy
        @contact.destroy
        head :no_content
      end

      # POST /api/v1/contacts/bulk_create
      def bulk_create
        contacts_data = params[:contacts] || []
        created_contacts = []
        errors = []

        contacts_data.each_with_index do |contact_data, index|
          contact = Contact.new(contact_data.permit(
            :account_id, :company_id, :first_name, :last_name, :email, :phone,
            :title, :department, :is_primary, :notes
          ))

          if contact.save
            created_contacts << contact
          else
            errors << { index: index, errors: contact.errors.full_messages }
          end
        end

        render json: {
          created: created_contacts.map { |c| contact_json(c) },
          errors: errors,
          summary: {
            total: contacts_data.length,
            created: created_contacts.length,
            failed: errors.length
          }
        }, status: (errors.any? ? :multi_status : :created)
      end

      # POST /api/v1/contacts/:id/tags
      def add_tags
        tag_names = params[:tags] || []
        added_tags = []

        tag_names.each do |tag_name|
          tag = Tag.find_or_create_by(name: tag_name.strip)
          unless @contact.tags.include?(tag)
            @contact.tags << tag
            added_tags << tag
          end
        end

        render json: {
          contact: contact_json(@contact, detailed: true),
          added_tags: added_tags.map { |t| { id: t.id, name: t.name } }
        }
      end

      # DELETE /api/v1/contacts/:id/tags/:tag_name
      def remove_tag
        tag = @contact.tags.find_by(name: params[:tag_name])

        if tag
          @contact.tags.delete(tag)
          render json: { message: 'Tag removed successfully' }
        else
          render json: { error: 'Tag not found' }, status: :not_found
        end
      end

      # PATCH /api/v1/contacts/:id/opt_in_email
      def opt_in_email
        @contact.opt_in_email!
        render json: {
          message: 'Contact opted in to email communications',
          contact: contact_json(@contact, detailed: true)
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/contacts/:id/opt_out_email
      def opt_out_email
        @contact.opt_out_email!(params[:reason])
        render json: {
          message: 'Contact opted out of email communications',
          contact: contact_json(@contact, detailed: true)
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/contacts/:id/opt_in_sms
      def opt_in_sms
        @contact.opt_in_sms!
        render json: {
          message: 'Contact opted in to SMS communications',
          contact: contact_json(@contact, detailed: true)
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/contacts/:id/opt_out_sms
      def opt_out_sms
        @contact.opt_out_sms!(params[:reason])
        render json: {
          message: 'Contact opted out of SMS communications',
          contact: contact_json(@contact, detailed: true)
        }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/contacts/:id/deals
      def deals
        if @contact.account.nil?
          render json: {
            success: true,
            deals: []
          }
          return
        end

        @deals = @contact.account.deals.order(created_at: :desc)
        
        render json: {
          success: true,
          deals: @deals.map { |deal| {
            id: deal.id,
            accountId: deal.account_id,
            leadId: deal.lead_id,
            title: deal.title,
            stage: deal.stage,
            amount: deal.amount_cents / 100.0,
            expectedCloseOn: deal.expected_close_on,
            createdAt: deal.created_at,
            updatedAt: deal.updated_at
          }}
        }
      rescue => e
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/contacts/:id/quotes
      def quotes
        @quotes = Quote.where(contact_id: @contact.id)
                       .or(Quote.where(account_id: @contact.account_id))
                       .where(is_deleted: false)
                       .order(created_at: :desc)
        
        render json: {
          success: true,
          quotes: @quotes.map { |quote| {
            id: quote.id,
            accountId: quote.account_id,
            contactId: quote.contact_id,
            quoteNumber: quote.quote_number,
            status: quote.status,
            subtotal: quote.subtotal,
            tax: quote.tax,
            total: quote.total,
            items: quote.items,
            validUntil: quote.valid_until,
            sentAt: quote.sent_at,
            viewedAt: quote.viewed_at,
            acceptedAt: quote.accepted_at,
            rejectedAt: quote.rejected_at,
            notes: quote.notes,
            createdAt: quote.created_at,
            updatedAt: quote.updated_at
          }}
        }
      rescue => e
        render json: { error: e.message }, status: :internal_server_error
      end

      private

      def set_contact
        @contact = Contact.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Contact not found' }, status: :not_found
      end

      def set_account
        @account = Account.find(params[:account_id]) if params[:account_id]
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Account not found' }, status: :not_found
      end

      def contact_params
        # Transform camelCase keys to snake_case
        contact_data = params.require(:contact).to_unsafe_h
        transformed_params = transform_keys_to_snake_case(contact_data)
        
        ActionController::Parameters.new(transformed_params).permit(
          :account_id,
          :company_id,
          :first_name,
          :last_name,
          :email,
          :phone,
          :title,
          :department,
          :is_primary,
          :notes
        )
      end

      # Helper to access extra params like tags
      def contact_params_with_extra
        contact_data = params.require(:contact).to_unsafe_h
        transformed_params = transform_keys_to_snake_case(contact_data)
        
        ActionController::Parameters.new(transformed_params).permit(
          :account_id,
          :company_id,
          :first_name,
          :last_name,
          :email,
          :phone,
          :title,
          :department,
          :is_primary,
          :notes,
          tags: []
        )
      end

      # Transform camelCase keys to snake_case
      def transform_keys_to_snake_case(hash)
        hash.transform_keys { |key| key.to_s.underscore.to_sym }
      end

      def apply_filters(contacts)
        contacts = contacts.where(account_id: params[:account_id]) if params[:account_id].present?
        contacts = contacts.where(department: params[:department]) if params[:department].present?
        contacts = contacts.where(title: params[:title]) if params[:title].present?
        contacts = contacts.where(is_primary: params[:is_primary]) if params[:is_primary].present?
        contacts = contacts.with_email if params[:has_email] == 'true'
        contacts = contacts.with_phone if params[:has_phone] == 'true'

        # Tag filtering
        if params[:tag_ids].present?
          tag_ids = params[:tag_ids].split(',').map(&:to_i)
          contacts = contacts.joins(:tags).where(tags: { id: tag_ids }).distinct
        end

        contacts
      end

      def apply_sorting(contacts)
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc

        case sort_by
        when 'name'
          contacts.order(first_name: sort_order, last_name: sort_order)
        when 'email'
          contacts.order(email: sort_order)
        when 'updated_at'
          contacts.order(updated_at: sort_order)
        else
          contacts.order(created_at: sort_order)
        end
      end

      def contact_json(contact, detailed: false)
        json = {
          id: contact.id,
          accountId: contact.account_id,
          companyId: contact.company_id,
          firstName: contact.first_name,
          lastName: contact.last_name,
          fullName: contact.full_name,
          email: contact.email,
          phone: contact.phone,
          title: contact.title,
          department: contact.department,
          isPrimary: contact.is_primary,
          notes: contact.notes,
          createdAt: contact.created_at,
          updatedAt: contact.updated_at
        }

        if detailed
          json.merge!(
            tags: contact.tags.map { |t| { id: t.id, name: t.name, color: t.color } },
            account: contact.account ? {
              id: contact.account.id,
              name: contact.account.name,
              status: contact.account.status
            } : nil,
            contactMethods: contact.contact_methods,
            notesCount: contact.note_records.count
          )
        end

        json
      end

      def handle_tags(contact, tag_names)
        return unless tag_names.is_a?(Array)

        # Remove existing tags not in the new list
        current_tag_names = contact.tags.pluck(:name)
        tags_to_remove = current_tag_names - tag_names
        tags_to_remove.each do |tag_name|
          tag = contact.tags.find_by(name: tag_name)
          contact.tags.delete(tag) if tag
        end

        # Add new tags
        tag_names.each do |tag_name|
          next if tag_name.blank?
          tag = Tag.find_or_create_by(name: tag_name.strip)
          contact.tags << tag unless contact.tags.include?(tag)
        end
      end
    end
  end
end
