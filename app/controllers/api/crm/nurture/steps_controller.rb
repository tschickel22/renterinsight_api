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
            :include_inventory, :inventory_display_mode,
            attachments: [:s3_key, :filename, :size, :content_type, :delivery_mode]
          )
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
            createdAt: step.created_at&.iso8601,
            updatedAt: step.updated_at&.iso8601
          }
        end
      end
    end
  end
end
