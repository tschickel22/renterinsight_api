# frozen_string_literal: true

module Api
  module Portal
    class ConfiguratorController < ApplicationController
      # Match the pattern used by InvoicesController, ServiceTicketsController, etc.
      # Portal::BaseController uses a DIFFERENT auth method (authenticate_portal_contact)
      # that expects contact_id in JWT - but portal login and proxy tokens use
      # buyer_portal_access_id. authenticate_portal_buyer! handles both correctly.
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!
      before_action :set_portal_context

      private

      def set_portal_context
        unless current_portal_buyer
          render json: { error: 'Unauthorized' }, status: :unauthorized
          return
        end

        @current_contact = current_portal_buyer.buyer
        @company = ::Company.find_by(id: current_portal_buyer.company_id)

        unless @company
          render json: { error: 'Company not found' }, status: :not_found
          return
        end

        unless @current_contact
          render json: { error: 'Contact not found' }, status: :not_found
          return
        end
      end

      public

      # GET /api/portal/configurator/settings
      # Returns configurator settings (pricing visibility, etc.)
      def settings
        configurator_settings = Setting.get('Company', @company.id, 'configurator', {})

        render json: {
          show_pricing: configurator_settings['show_pricing'] != false, # default true
          show_price_ranges: configurator_settings['show_price_ranges'] != false,
          allow_submissions: configurator_settings['allow_portal_submissions'] != false,
          welcome_message: configurator_settings['portal_welcome_message'],
        }
      end

      # GET /api/portal/configurator/floor-plans
      # Browse company's published floor plans
      def floor_plans
        company_fps = @company.company_floor_plans
                              .visible
                              .includes(:floor_plan)
                              .ordered

        # Optional filters
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

        # Pricing visibility
        show_pricing = configurator_show_pricing?

        render json: {
          floor_plans: company_fps.map { |cfp| portal_floor_plan_json(cfp, show_pricing) },
          show_pricing: show_pricing
        }
      end

      # GET /api/portal/configurator/floor-plans/:id
      # Floor plan detail with option categories and options
      def floor_plan_detail
        cfp = @company.company_floor_plans.visible.find_by(floor_plan_id: params[:id])

        unless cfp
          return render json: { error: 'Floor plan not found' }, status: :not_found
        end

        fp = cfp.floor_plan
        show_pricing = configurator_show_pricing?

        # Get option categories with options
        categories = fp.option_categories.order(:display_order).includes(:floor_plan_options)

        render json: {
          floor_plan: portal_floor_plan_json(cfp, show_pricing),
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

      # POST /api/portal/configurator/submit
      # Submit configuration — creates Config + Lead + Notification
      def submit
        fp = @company.company_floor_plans.visible.find_by(floor_plan_id: params[:floor_plan_id])
        unless fp
          return render json: { error: 'Floor plan not found' }, status: :not_found
        end

        # Create configuration
        config = @company.configurations.build(
          floor_plan_id: params[:floor_plan_id],
          name: params[:name].presence || "#{@current_contact.full_name}'s Build",
          notes: params[:notes],
          selections: params[:selected_option_ids] || [],
          status: 'draft',
          configurable: @current_contact
        )

        # Calculate pricing
        calculate_configuration_pricing(config, fp)

        if config.save
          # Create lead from portal contact
          lead = create_lead_from_portal_submission(config, @current_contact)

          # Create note on the lead with config details
          create_configuration_note(lead, config) if lead

          render json: {
            success: true,
            configuration: {
              id: config.id,
              public_token: config.public_token,
              public_url: "#{request.base_url}/c/#{config.public_token}",
              name: config.name
            },
            lead: lead ? { id: lead.id, status: lead.status } : nil,
            message: 'Your home configuration has been submitted! Our team will be in touch shortly.'
          }, status: :created
        else
          render json: { error: config.errors.full_messages.join(', ') }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[PortalConfigurator] Submit error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: 'Failed to submit configuration' }, status: :internal_server_error
      end

      # GET /api/portal/configurator/my-configurations
      # List current contact's saved configurations
      def my_configurations
        configs = @company.configurations
                          .where(configurable: @current_contact)
                          .includes(:floor_plan)
                          .order(created_at: :desc)

        show_pricing = configurator_show_pricing?

        render json: {
          configurations: configs.map { |c| saved_config_json(c, show_pricing) }
        }
      end

      private

      def configurator_show_pricing?
        settings = Setting.get('Company', @company.id, 'configurator', {})
        settings['show_pricing'] != false # default true
      end

      def portal_floor_plan_json(cfp, show_pricing)
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

      def saved_config_json(config, show_pricing)
        fp = config.floor_plan
        data = {
          id: config.id,
          name: config.name,
          status: config.status,
          public_token: config.public_token,
          public_url: "#{request.base_url}/c/#{config.public_token}",
          created_at: config.created_at,
          floor_plan: {
            name: fp&.name,
            model_code: fp&.model_code,
            bedrooms: fp&.beds,
            bathrooms: fp&.baths,
            sqft: fp&.sqft,
            primary_image_url: fp&.primary_image_url
          },
          selected_option_count: (config.selections || []).length
        }

        if show_pricing
          data[:total_price_low] = config.price_range_low
          data[:total_price_high] = config.price_range_high
        end

        data
      end

      def calculate_configuration_pricing(config, company_fp)
        fp = company_fp.floor_plan
        base_low = company_fp.base_price_low || fp.base_price_low || 0
        base_high = company_fp.base_price_high || fp.base_price_high || 0

        options_low = 0
        options_high = 0

        if config.selections.present?
          selected_options = FloorPlanOption.where(id: config.selections)
          selected_options.each do |opt|
            options_low += (opt.price_impact_low || 0)
            options_high += (opt.price_impact_high || 0)
          end
        end

        config.base_price = base_low # Store base for reference
        config.options_total = options_low
        config.price_range_low = base_low + options_low
        config.price_range_high = base_high + options_high
      end

      def create_lead_from_portal_submission(config, contact)
        # Find or create "Home Configurator" source
        source = Source.find_or_create_by(
          company_id: @company.id,
          name: 'Home Configurator'
        ) do |s|
          s.is_active = true
          s.description = 'Leads from the home configurator tool'
        end

        fp = config.floor_plan

        lead = Lead.create!(
          company_id: @company.id,
          first_name: contact.first_name,
          last_name: contact.last_name,
          email: contact.email,
          phone: contact.phone,
          source_id: source.id,
          status: 'new',
          location_id: contact.location_id
        )

        Rails.logger.info "[PortalConfigurator] Lead #{lead.id} created from portal contact #{contact.id}"

        # Trigger notification to company users
        notify_team_of_new_lead(lead, config)

        lead
      rescue => e
        Rails.logger.error "[PortalConfigurator] Lead creation failed: #{e.message}"
        nil
      end

      def notify_team_of_new_lead(lead, config)
        fp = config.floor_plan

        # Find user to notify — owner, or first active admin
        notified_user = lead.owner || @company.users.where(status: 'active')
                                                    .where(role: ['admin', 'company_admin', 'platform_admin'])
                                                    .first

        return unless notified_user

        activity = LeadActivity.create!(
          lead_id: lead.id,
          user_id: notified_user.id,
          activity_type: 'reminder',
          subject: "🏠 New Configurator Lead: #{lead.first_name} #{lead.last_name}",
          description: "#{lead.first_name} #{lead.last_name} submitted a home configuration for #{fp&.name || 'a floor plan'}. " \
                       "Contact: #{lead.email || lead.phone || 'N/A'}",
          priority: 'high',
          status: 'pending',
          reminder_time: Time.current,
          reminder_sent: false
        )

        ActivityReminderService.send_reminder(activity)

        Rails.logger.info "[PortalConfigurator] Notification sent to user #{notified_user.id} for lead #{lead.id}"
      rescue => e
        Rails.logger.error "[PortalConfigurator] Notification failed: #{e.message}"
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
            note_lines << "Estimated Price Range: $#{config.price_range_low&.to_f&.round(2)} - $#{config.price_range_high&.to_f&.round(2)}"
          end
        end

        note_lines << ""
        note_lines << "Configuration Link: #{request.base_url}/c/#{config.public_token}"
        note_lines << "Submitted via: Customer Portal"

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
        Rails.logger.error "[PortalConfigurator] Note creation failed: #{e.message}"
      end
    end
  end
end
