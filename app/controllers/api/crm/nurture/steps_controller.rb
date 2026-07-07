module Api
  module Crm
    module Nurture
      class StepsController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm

        MAX_ATTACHMENT_SIZE = 25.megabytes

        before_action :set_company_scope
        before_action :load_sequence

        # GET /api/crm/nurture/sequences/:sequence_id/steps
        def index
          render json: @sequence.nurture_steps.order(:position).map { |s| step_json(s) }
        end

        # GET /api/crm/nurture/sequences/:sequence_id/steps/:id
        def show
          step = @sequence.nurture_steps.find_by(id: params[:id])
          unless step
            render json: { error: 'Step not found' }, status: :not_found
            return
          end
          render json: step_json(step)
        end

        # POST /api/crm/nurture/sequences/:sequence_id/steps
        def create
          step = @sequence.nurture_steps.build(step_params)
          if step.save
            render json: step_json(step), status: :created
          else
            render json: { errors: step.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH/PUT /api/crm/nurture/sequences/:sequence_id/steps/:id
        def update
          step = @sequence.nurture_steps.find_by(id: params[:id])
          unless step
            render json: { error: 'Step not found' }, status: :not_found
            return
          end

          if step.update(step_params)
            render json: step_json(step)
          else
            render json: { errors: step.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/crm/nurture/sequences/:sequence_id/steps/:id
        def destroy
          step = @sequence.nurture_steps.find_by(id: params[:id])
          unless step
            render json: { error: 'Step not found' }, status: :not_found
            return
          end

          step.destroy
          head :no_content
        end

        # POST /api/crm/nurture/sequences/:sequence_id/steps/:id/upload_attachment
        # Multipart upload — stores file in S3, appends metadata to step.attachments JSONB
        def upload_attachment
          step = @sequence.nurture_steps.find_by(id: params[:id])
          unless step
            render json: { error: 'Step not found' }, status: :not_found
            return
          end

          file = params[:file]
          unless file.present?
            render json: { error: 'No file provided' }, status: :unprocessable_entity
            return
          end

          if file.size > MAX_ATTACHMENT_SIZE
            render json: { error: "File too large. Maximum size is #{MAX_ATTACHMENT_SIZE / 1.megabyte}MB" },
                   status: :unprocessable_entity
            return
          end

          delivery_mode = params[:delivery_mode].presence || 'tracked_link'
          unless %w[tracked_link inline_attachment].include?(delivery_mode)
            render json: { error: "Invalid delivery_mode (tracked_link|inline_attachment)" },
                   status: :unprocessable_entity
            return
          end

          begin
            s3_service = S3UploadService.new
            folder = "nurture_attachments/#{@company.id}/#{@sequence.id}/#{step.id}"
            s3_result = s3_service.upload(file, folder: folder)

            entry = {
              's3_key'        => s3_result[:key],
              'filename'      => file.original_filename,
              'size'          => s3_result[:size],
              'content_type'  => s3_result[:content_type],
              'delivery_mode' => delivery_mode
            }

            attachments = Array(step.attachments)
            attachments << entry
            step.update!(attachments: attachments)

            render json: entry, status: :created
          rescue => e
            Rails.logger.error "[Nurture::Steps] upload_attachment failed: #{e.message}"
            render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
          end
        end

        # POST /api/crm/nurture/sequences/:sequence_id/steps/:id/send_test
        # Renders the step against a real entity (param-specified or most-recent Lead),
        # injects banner + tracked links + inventory block, and sends to current_user.
        def send_test
          step = @sequence.nurture_steps.find_by(id: params[:id])
          unless step
            render json: { error: 'Step not found' }, status: :not_found
            return
          end

          unless step.step_type == 'email' || step.channel == 'email'
            render json: { error: 'Only email steps can be tested' }, status: :unprocessable_entity
            return
          end

          test_entity = resolve_test_entity
          unless test_entity
            render json: { error: 'No leads or contacts found to use as test data' },
                   status: :unprocessable_entity
            return
          end

          subject = step.subject.to_s.dup
          body    = step.body.to_s.dup

          merge_data = build_test_merge_data(test_entity)
          merge_data.each do |tag, value|
            body.gsub!("{{#{tag}}}", value.to_s)
            subject.gsub!("{{#{tag}}}", value.to_s)
          end

          test_entity_name = if test_entity.respond_to?(:first_name)
                               [test_entity.first_name, test_entity.last_name].compact.join(' ')
                             else
                               test_entity.try(:name) || 'Unknown'
                             end

          banner = +'<div style="padding: 12px; background-color: #FEF3C7; border: 1px solid #F59E0B; '
          banner << 'border-radius: 6px; margin-bottom: 16px; font-size: 14px;">'
          banner << '<strong>⚠️ TEST EMAIL</strong> — Step #' << step.position.to_s
          banner << ' from "' << ERB::Util.html_escape(@sequence.name.to_s) << '". '
          banner << 'Test data from ' << test_entity.class.name << ': '
          banner << ERB::Util.html_escape(test_entity_name)
          banner << '</div>'
          body = banner + body

          inline_attachments = []
          (step.attachments || []).each do |att|
            case att['delivery_mode']
            when 'tracked_link'
              tracked_link = TrackedLink.create_for_attachment!(
                company:      @company,
                s3_key:       att['s3_key'],
                filename:     att['filename'],
                content_type: att['content_type'],
                file_size:    att['size'],
                entity_type:  test_entity.class.name,
                entity_id:    test_entity.id,
                source_type:  'NurtureStep',
                source_id:    step.id
              )
              safe_filename = ERB::Util.html_escape(att['filename'].to_s)
              body += %(<p style="margin: 8px 0;"><a href="#{tracked_link.tracking_url}" style="color: #C44C3D;">📎 #{safe_filename}</a></p>)
            when 'inline_attachment'
              uploaded = download_attachment_for_test(att)
              inline_attachments << uploaded if uploaded
            end
          end

          inventory_info = nil
          inventory_inline_images = []
          if step.include_inventory
            matcher  = InventoryMatcherService.new(test_entity, @company)
            vehicles = matcher.match
            if vehicles.present?
              block_builder = InventoryEmailBlockBuilder.new(
                company:     @company,
                entity:      test_entity,
                vehicles:    vehicles,
                source_type: 'NurtureStep',
                source_id:   step.id
              )
              body += block_builder.build_html
              inventory_inline_images = block_builder.inline_images
              inventory_info = {
                match_mode:      matcher.match_mode,
                vehicles_count:  vehicles.size,
                vehicles:        vehicles.map { |v| [v.year, v.make, v.model].compact.join(' ') }
              }
            else
              body += '<div style="padding: 12px; background-color: #F3F4F6; border-radius: 6px; ' \
                      'margin-top: 16px; font-size: 13px; color: #6B7280;">' \
                      "<em>ℹ️ No matching inventory found for this test. In production, this block only " \
                      "appears when homes match the recipient's preferences or available inventory exists.</em>" \
                      '</div>'
              inventory_info = { match_mode: 'none', vehicles_count: 0, vehicles: [] }
            end
          end

          recipient_email = current_user.email
          begin
            CommunicationService.send_email(
              communicable:           test_entity,
              to:                     recipient_email,
              subject:                "[TEST] #{subject}",
              body:                   body,
              category:               'nurture',
              content_type:           'text/html',
              attachments:            inline_attachments.presence,
              inline_images:          inventory_inline_images,
              skip_preference_check:  true,
              metadata:               {
                nurture_step_id:        step.id,
                nurture_sequence_id:    @sequence.id,
                test_send:              true,
                test_entity_type:       test_entity.class.name,
                test_entity_id:         test_entity.id
              }
            )

            render json: {
              success:           true,
              message:           "Test email sent to #{recipient_email}",
              test_entity:       { type: test_entity.class.name, name: test_entity_name, id: test_entity.id },
              inventory:         inventory_info,
              attachments_count: Array(step.attachments).size
            }
          rescue => e
            Rails.logger.error "[NurtureTest] Failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
            render json: { error: "Failed to send test email: #{e.message}" },
                   status: :internal_server_error
          ensure
            inline_attachments.each do |u|
              tmp = u.respond_to?(:tempfile) ? u.tempfile : nil
              begin
                tmp&.close
                tmp&.unlink
              rescue StandardError
                nil
              end
            end
          end
        end

        # DELETE /api/crm/nurture/sequences/:sequence_id/steps/:id/remove_attachment
        # Body: { s3_key: "..." } — removes from S3 and from step.attachments
        def remove_attachment
          step = @sequence.nurture_steps.find_by(id: params[:id])
          unless step
            render json: { error: 'Step not found' }, status: :not_found
            return
          end

          s3_key = params[:s3_key]
          unless s3_key.present?
            render json: { error: 'No s3_key provided' }, status: :unprocessable_entity
            return
          end

          expected_prefix = "nurture_attachments/#{@company.id}/"
          unless s3_key.start_with?(expected_prefix)
            render json: { error: 'Access denied' }, status: :forbidden
            return
          end

          begin
            S3UploadService.new.delete(s3_key)
            remaining = Array(step.attachments).reject { |a| a['s3_key'] == s3_key }
            step.update!(attachments: remaining)
            render json: { message: 'Attachment removed' }
          rescue => e
            Rails.logger.error "[Nurture::Steps] remove_attachment failed: #{e.message}"
            render json: { error: "Delete failed: #{e.message}" }, status: :internal_server_error
          end
        end

        private

        def set_company_scope
          unless current_user
            Rails.logger.error "🚫 [Nurture::StepsController] No authenticated user found"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end

          company_id = current_company_id

          unless company_id.present?
            Rails.logger.error "🚫 [Nurture::StepsController] No company context available"
            render json: { error: 'No company context' }, status: :forbidden
            return
          end

          @company = ::Company.find_by(id: company_id)

          if @company.nil?
            Rails.logger.error "🚫 [Nurture::StepsController] Company #{company_id} not found"
            render json: { error: 'Company not found' }, status: :not_found
            return
          end

          Rails.logger.info "✅ [Nurture::StepsController] Company scope set: #{@company.name} (ID: #{@company.id})"
        end

        def load_sequence
          @sequence = @company.nurture_sequences.find_by(id: params[:sequence_id])
          unless @sequence
            render json: { error: 'Sequence not found or access denied' }, status: :not_found
            return
          end
        end

        def step_params
          params.require(:step).permit(
            :position, :step_type, :subject, :body, :wait_hours, :wait_days, :template_id,
            :include_inventory, :inventory_display_mode, :inventory_require_images,
            inventory_statuses: [],
            attachments: [:s3_key, :filename, :size, :content_type, :delivery_mode]
          )
        end

        def resolve_test_entity
          if params[:entity_id].present? && params[:entity_type].present?
            case params[:entity_type]
            when 'Lead'    then return @company.leads.find_by(id: params[:entity_id])
            when 'Contact' then return @company.contacts.find_by(id: params[:entity_id])
            end
          end
          @company.leads.order(created_at: :desc).first
        end

        def build_test_merge_data(entity)
          data = {}
          if entity.respond_to?(:first_name)
            data['first_name'] = entity.first_name.to_s
            data['last_name']  = entity.last_name.to_s
            data['email']      = entity.try(:email).to_s
            data['phone']      = entity.try(:phone).to_s
          end
          data['name'] = entity.name.to_s if entity.respond_to?(:name)

          company = entity.try(:company)
          data['company_name']  = company&.name.to_s
          data['company_phone'] = company&.try(:phone).to_s
          data['company_email'] = company&.try(:email).to_s

          owner = entity.try(:owner) || entity.try(:assigned_to)
          if owner
            data['rep_name']  = [owner.try(:first_name), owner.try(:last_name)].compact.join(' ')
            data['rep_email'] = owner.try(:email).to_s
            data['rep_phone'] = owner.try(:phone).to_s
          end

          vehicle = entity.try(:preferred_vehicle)
          vehicle ||= Vehicle.find_by(id: entity.vehicle_id) if entity.respond_to?(:vehicle_id) && entity.vehicle_id.present?
          if vehicle
            data['home_name']      = [vehicle.try(:year), vehicle.try(:make), vehicle.try(:model)].compact.join(' ')
            data['home_price']     = format_currency(vehicle.try(:sale_price))
            data['home_bedrooms']  = vehicle.try(:bedrooms).to_s
            data['home_bathrooms'] = vehicle.try(:bathrooms).to_s
          end

          data
        end

        def format_currency(amount)
          return '' if amount.blank?
          "$#{amount.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse}"
        end

        def download_attachment_for_test(att)
          require 'aws-sdk-s3'
          s3_client = Aws::S3::Client.new(
            region:            ENV['AWS_REGION'] || 'us-west-2',
            access_key_id:     ENV['AWS_ACCESS_KEY_ID'],
            secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
          )
          bucket = ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging'

          tempfile = Tempfile.new(['nurture_test_att', File.extname(att['filename'].to_s)])
          tempfile.binmode
          s3_client.get_object({ bucket: bucket, key: att['s3_key'] }) do |chunk|
            tempfile.write(chunk)
          end
          tempfile.rewind

          ActionDispatch::Http::UploadedFile.new(
            tempfile: tempfile,
            filename: att['filename'],
            type:     att['content_type'] || 'application/octet-stream'
          )
        rescue => e
          Rails.logger.warn "[NurtureTest] Failed to download attachment #{att['s3_key']}: #{e.message}"
          nil
        end

        def step_json(step)
          {
            id: step.id,
            step_type: step.step_type || 'email',
            type: step.step_type || 'email',
            subject: step.subject || '',
            body: step.body || '',
            wait_days: step.wait_days || 0,
            waitDays: step.wait_days || 0,
            position: step.position || 0,
            order: step.position || 0,
            template_id: step.template_id,
            templateId: step.template_id,
            nurture_sequence_id: step.nurture_sequence_id,
            nurtureSequenceId: step.nurture_sequence_id,
            attachments: Array(step.attachments),
            include_inventory: !!step.include_inventory,
            includeInventory: !!step.include_inventory,
            inventory_display_mode: step.inventory_display_mode,
            inventoryDisplayMode: step.inventory_display_mode,
            inventory_statuses: Array(step.try(:inventory_statuses)),
            inventoryStatuses: Array(step.try(:inventory_statuses)),
            inventory_require_images: !!step.try(:inventory_require_images),
            inventoryRequireImages: !!step.try(:inventory_require_images),
            createdAt: step.created_at&.iso8601,
            updatedAt: step.updated_at&.iso8601
          }
        end
      end
    end
  end
end
