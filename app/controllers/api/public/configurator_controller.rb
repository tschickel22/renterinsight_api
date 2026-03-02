# frozen_string_literal: true

module Api
  module Public
    class ConfiguratorController < ApplicationController
      skip_before_action :authenticate

      before_action :set_company_from_subdomain, only: [:company_info, :floor_plans, :floor_plan_detail, :submit]

      # GET /api/public/configurator/:subdomain/info
      # Returns company info + configurator settings for the public builder
      def company_info
        branding = @company.branding_settings rescue {}
        configurator_settings = Setting.get('Company', @company.id, 'configurator', {})

        render json: {
          company: {
            name: @company.name,
            logo_url: branding.dig('logo_url') || @company.logo_url,
            phone: @company.phone,
            email: @company.email,
            website: @company.website
          },
          settings: {
            show_pricing: configurator_settings['show_public_pricing'] != false,
            welcome_message: configurator_settings['public_welcome_message'],
            require_contact_info: true # Always require for public submissions
          }
        }
      end

      # GET /api/public/configurator/:subdomain/floor-plans
      # Browse company's published floor plans (no auth)
      def floor_plans
        company_fps = @company.company_floor_plans
                              .visible
                              .includes(:floor_plan)
                              .ordered

        # Filters
        if params[:manufacturer_id].present?
          company_fps = company_fps.joins(:floor_plan)
                                   .where(floor_plans: { manufacturer_id: params[:manufacturer_id] })
        end

        if params[:beds].present?
          company_fps = company_fps.joins(:floor_plan).where(floor_plans: { beds: params[:beds] })
        end

        if params[:baths].present?
          company_fps = company_fps.joins(:floor_plan).where(floor_plans: { baths: params[:baths] })
        end

        if params[:sections].present?
          company_fps = company_fps.joins(:floor_plan).where(floor_plans: { sections: params[:sections] })
        end

        if params[:search].present?
          term = "%#{params[:search]}%"
          company_fps = company_fps.joins(:floor_plan)
                                   .where("floor_plans.name ILIKE ? OR floor_plans.model_code ILIKE ?", term, term)
        end

        show_pricing = public_show_pricing?

        render json: {
          floor_plans: company_fps.map { |cfp| public_floor_plan_json(cfp, show_pricing) },
          show_pricing: show_pricing
        }
      end

      # GET /api/public/configurator/:subdomain/floor-plans/:id
      # Floor plan detail with options (no auth)
      def floor_plan_detail
        cfp = @company.company_floor_plans.visible.find_by(floor_plan_id: params[:id])

        unless cfp
          return render json: { error: 'Floor plan not found' }, status: :not_found
        end

        fp = cfp.floor_plan
        show_pricing = public_show_pricing?

        categories = fp.option_categories.order(:display_order).includes(:floor_plan_options)

        render json: {
          floor_plan: public_floor_plan_json(cfp, show_pricing),
          option_categories: categories.map { |cat|
            {
              id: cat.id,
              name: cat.name,
              description: cat.description,
              display_order: cat.display_order,
              selection_type: cat.selection_type,
              is_required: cat.is_required,
              options: cat.floor_plan_options.order(:display_order).map { |opt|
                option_data = {
                  id: opt.id,
                  name: opt.name,
                  description: opt.description,
                  display_order: opt.display_order,
                  is_default: opt.is_default,
                  image_url: opt.image_url
                }
                if show_pricing
                  option_data[:price_impact_low] = opt.price_impact_low
                  option_data[:price_impact_high] = opt.price_impact_high
                end
                option_data
              }
            }
          },
          show_pricing: show_pricing
        }
      end

      # POST /api/public/configurator/:subdomain/submit
      # Anonymous submission — requires contact info, creates Config + Lead + Notification
      def submit
        # Validate contact info
        unless params[:first_name].present? && (params[:email].present? || params[:phone].present?)
          return render json: { error: 'Name and email or phone are required' }, status: :unprocessable_entity
        end

        fp = @company.company_floor_plans.visible.find_by(floor_plan_id: params[:floor_plan_id])
        unless fp
          return render json: { error: 'Floor plan not found' }, status: :not_found
        end

        # Create configuration
        config = @company.configurations.build(
          floor_plan_id: params[:floor_plan_id],
          name: params[:name].presence || "#{params[:first_name]}'s Build",
          notes: params[:notes],
          selections: params[:selected_option_ids] || [],
          status: 'draft'
        )

        # Calculate pricing
        calculate_pricing(config, fp)

        if config.save
          # Create lead from anonymous contact info
          lead = create_lead_from_public_submission(config, params)

          # Link config to lead if possible
          if lead
            config.update_columns(configurable_type: 'Lead', configurable_id: lead.id)
            create_configuration_note(lead, config)
          end

          render json: {
            success: true,
            configuration: {
              id: config.id,
              public_token: config.public_token,
              public_url: "#{request.base_url}/c/#{config.public_token}"
            },
            message: 'Your home configuration has been submitted! Our team will be in touch shortly.'
          }, status: :created
        else
          render json: { error: config.errors.full_messages.join(', ') }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[PublicConfigurator] Submit error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: 'Failed to submit configuration' }, status: :internal_server_error
      end

      private

      def set_company_from_subdomain
        subdomain = params[:subdomain]

        @company = Company.find_by(subdomain: subdomain, status: 'active')
        @company ||= Company.find_by(id: subdomain, status: 'active') # Fallback to ID for dev/testing

        unless @company
          render json: { error: 'Company not found' }, status: :not_found
        end
      end

      def public_show_pricing?
        settings = Setting.get('Company', @company.id, 'configurator', {})
        settings['show_public_pricing'] != false
      end

      def public_floor_plan_json(cfp, show_pricing)
        fp = cfp.floor_plan
        data = {
          id: fp.id,
          name: fp.name,
          model_code: fp.model_code,
          manufacturer_name: fp.manufacturer&.name,
          bedrooms: fp.beds,
          bathrooms: fp.baths,
          sqft: fp.sqft,
          width_ft: fp.width_ft,
          length_ft: fp.length_ft,
          sections: fp.sections,
          description: fp.description,
          primary_image_url: fp.primary_image_url,
          floor_plan_image_url: fp.floor_plan_image_url,
          images: fp.images_array
        }

        if show_pricing
          data[:base_price_low] = cfp.base_price_low || fp.base_price_low
          data[:base_price_high] = cfp.base_price_high || fp.base_price_high
        end

        data
      end

      def calculate_pricing(config, company_fp)
        fp = company_fp.floor_plan
        base_low = company_fp.base_price_low || fp.base_price_low || 0
        base_high = company_fp.base_price_high || fp.base_price_high || 0

        options_low = 0
        options_high = 0

        if config.selections.present?
          FloorPlanOption.where(id: config.selections).each do |opt|
            options_low += (opt.price_impact_low || 0)
            options_high += (opt.price_impact_high || 0)
          end
        end

        config.base_price = base_low
        config.options_total = options_low
        config.price_range_low = base_low + options_low
        config.price_range_high = base_high + options_high
      end

      def create_lead_from_public_submission(config, contact_params)
        source = Source.find_or_create_by(
          company_id: @company.id,
          name: 'Home Configurator'
        ) do |s|
          s.is_active = true
          s.description = 'Leads from the home configurator tool'
        end

        lead = Lead.create!(
          company_id: @company.id,
          first_name: contact_params[:first_name],
          last_name: contact_params[:last_name],
          email: contact_params[:email],
          phone: contact_params[:phone],
          source_id: source.id,
          status: 'new'
        )

        Rails.logger.info "[PublicConfigurator] Lead #{lead.id} created from public submission"

        # Trigger notification using existing ActivityReminderService
        notify_team_of_new_lead(lead, config)

        lead
      rescue => e
        Rails.logger.error "[PublicConfigurator] Lead creation failed: #{e.message}"
        nil
      end

      def notify_team_of_new_lead(lead, config)
        fp = config.floor_plan

        # Find user to notify — first active admin
        notified_user = @company.users.where(is_active: true)
                                      .where(role: ['admin', 'company_admin', 'platform_admin'])
                                      .first

        return unless notified_user

        activity = LeadActivity.create!(
          lead_id: lead.id,
          user_id: notified_user.id,
          activity_type: 'reminder',
          subject: "🏠 New Configurator Lead: #{lead.first_name} #{lead.last_name}",
          description: "#{lead.first_name} #{lead.last_name} submitted a home configuration for #{fp&.name || 'a floor plan'}. " \
                       "Contact: #{lead.email || lead.phone || 'N/A'}. Source: Public Website",
          priority: 'high',
          status: 'pending',
          reminder_time: Time.current,
          reminder_sent: false
        )

        # Uses existing notification system — checks user's settings for bell/popup/email/SMS
        ActivityReminderService.send_reminder(activity)

        Rails.logger.info "[PublicConfigurator] Notification sent to user #{notified_user.id} for lead #{lead.id}"
      rescue => e
        Rails.logger.error "[PublicConfigurator] Notification failed: #{e.message}"
      end

      def create_configuration_note(lead, config)
        fp = config.floor_plan
        options = config.selected_options

        note_lines = []
        note_lines << "🏠 HOME CONFIGURATION"
        note_lines << "=" * 50
        note_lines << "Floor Plan: #{fp&.name} (#{fp&.model_code})"
        note_lines << "Specs: #{fp&.beds}bd / #{fp&.baths}ba / #{fp&.sqft} sqft"
        note_lines << "Sections: #{fp&.sections}" if fp&.sections.present?
        note_lines << ""

        if options.any?
          note_lines << "Selected Options:"
          options.includes(:option_category).group_by(&:option_category).each do |cat, opts|
            note_lines << "  #{cat&.name}:"
            opts.each { |o| note_lines << "    • #{o.name}" }
          end
          note_lines << ""
        end

        if config.price_range_low.present?
          if config.price_range_low == config.price_range_high
            note_lines << "Estimated Price: $#{config.price_range_low&.to_f&.round(2)}"
          else
            note_lines << "Price Range: $#{config.price_range_low&.to_f&.round(2)} - $#{config.price_range_high&.to_f&.round(2)}"
          end
        end

        note_lines << ""
        note_lines << "Configuration Link: #{request.base_url}/c/#{config.public_token}"
        note_lines << "Submitted via: Public Website (Anonymous)"

        if config.notes.present?
          note_lines << ""
          note_lines << "Customer Notes:"
          note_lines << config.notes
        end

        Note.create!(
          entity_type: 'lead',
          entity_id: lead.id,
          content: note_lines.join("\n"),
          created_by_name: 'System (Home Configurator)'
        )
      rescue => e
        Rails.logger.error "[PublicConfigurator] Note creation failed: #{e.message}"
      end
    end
  end
end
