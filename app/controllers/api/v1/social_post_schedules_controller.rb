# frozen_string_literal: true

class Api::V1::SocialPostSchedulesController < ApplicationController
  before_action :set_company_scope
  before_action :set_schedule, only: %i[show update destroy activate pause test_approval_email]

  # GET /api/v1/social-post-schedules
  def index
    return unless authorize_action!('social_posts', 'read')

    schedules = @company.social_post_schedules.where(is_deleted: [false, nil]).order(created_at: :desc)
    render json: schedules.map { |s| serialize(s) }
  end

  # GET /api/v1/social-post-schedules/:id
  def show
    return unless authorize_action!('social_posts', 'read')
    render json: serialize(@schedule, detailed: true)
  end

  # POST /api/v1/social-post-schedules
  def create
    return unless authorize_action!('social_posts', 'update')

    schedule = @company.social_post_schedules.new(permitted_params)
    schedule.next_scheduled_at ||= schedule.calculate_next_scheduled_at if schedule.frequency.present?

    if schedule.save
      render json: serialize(schedule, detailed: true), status: :created
    else
      render json: { errors: schedule.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/social-post-schedules/:id
  def update
    return unless authorize_action!('social_posts', 'update')

    if @schedule.update(permitted_params)
      # If frequency / preferred_times / days changed, recompute next_scheduled_at
      if %w[frequency preferred_times preferred_days].any? { |k| @schedule.saved_change_to_attribute?(k) }
        @schedule.update_column(:next_scheduled_at, @schedule.calculate_next_scheduled_at)
      end
      render json: serialize(@schedule, detailed: true)
    else
      render json: { errors: @schedule.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/social-post-schedules/:id
  def destroy
    return unless authorize_action!('social_posts', 'delete')
    @schedule.update!(is_deleted: true, active: false)
    head :no_content
  end

  # POST /api/v1/social-post-schedules/:id/activate
  def activate
    return unless authorize_action!('social_posts', 'update')

    @schedule.update!(active: true, next_scheduled_at: @schedule.calculate_next_scheduled_at)
    render json: serialize(@schedule, detailed: true)
  end

  # POST /api/v1/social-post-schedules/:id/pause
  def pause
    return unless authorize_action!('social_posts', 'update')

    @schedule.update!(active: false)
    render json: serialize(@schedule, detailed: true)
  end

  # POST /api/v1/social-post-schedules/:id/test_approval_email
  def test_approval_email
    return unless authorize_action!('social_posts', 'update')

    intent = ScheduleIntentPicker.next(rotation: Array(@schedule.intent_rotation), last: @schedule.last_intent_used)
    vehicle = SchedulePreviewVehiclePicker.pick_for(@schedule, intent: intent)

    post = @company.social_posts.create!(
      platform:           @schedule.platform,
      post_type:          @schedule.post_type,
      intent_category:    intent,
      status:             'draft',
      headline:           "[TEST] #{intent.to_s.titleize} Post",
      caption:            "This is a test approval email from schedule '#{@schedule.name}'. Intent: #{intent}. You can approve, edit, or decline to test the workflow.",
      vehicle_id:         vehicle&.id,
      image_urls:         vehicle ? [vehicle.try(:photo_url)].compact : [],
      created_by_user_id: current_user&.id,
      generation_context: { schedule_id: @schedule.id, test: true }
    )

    SocialPostMailer.approval_needed(post, current_user).deliver_later
    render json: { message: "Test approval email sent to #{current_user.email}", post_id: post.id }
  end

  # GET /api/v1/social-post-schedules/preview
  # Shows what the next 5 posts would look like based on inventory + rotation.
  def preview
    return unless authorize_action!('social_posts', 'read')

    schedule_id = params[:schedule_id] || params[:id]
    schedule = if schedule_id.present?
      @company.social_post_schedules.where(is_deleted: [false, nil]).find_by(id: schedule_id)
    else
      build_ephemeral_schedule_from_params
    end
    return render json: { error: 'Schedule not found' }, status: :not_found unless schedule

    previews = []
    last_intent = schedule.last_intent_used
    next_at = schedule.next_scheduled_at || schedule.calculate_next_scheduled_at(from: Time.current)

    5.times do
      intent = ::ScheduleIntentPicker.next(rotation: Array(schedule.intent_rotation), last: last_intent)
      vehicle = ::SchedulePreviewVehiclePicker.pick_for(schedule, intent: intent)
      previews << {
        scheduled_at:    next_at&.iso8601,
        intent_category: intent,
        vehicle: vehicle ? preview_vehicle(vehicle) : nil,
        platform:        schedule.platform,
        post_type:       schedule.post_type,
        tone:            schedule.tone,
        auto_approve:    schedule.auto_approve
      }
      last_intent = intent
      next_at = SocialPostSchedule.new(
        frequency:       schedule.frequency,
        preferred_times: schedule.preferred_times,
        preferred_days:  schedule.preferred_days,
        created_at:      schedule.created_at || Time.current
      ).calculate_next_scheduled_at(from: next_at)
    end

    render json: { schedule: serialize(schedule, detailed: true), upcoming: previews }
  end

  private

  def set_schedule
    @schedule = @company.social_post_schedules.where(is_deleted: [false, nil]).find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @schedule
  end

  def permitted_params
    params.require(:social_post_schedule).permit(
      :name, :frequency, :auto_approve, :require_vehicle, :platform, :post_type,
      :tone, :intake_form_id, :notify_user_id, :location_id, :active, :ends_at,
      :require_photos, :use_logo_fallback, :draft_retention_days,
      preferred_times:    [],
      preferred_days:     [],
      intent_rotation:    [],
      inventory_statuses: [],
      image_pool:         [],
      intent_notes:       {} # { intent => optional idea text }
    )
  end

  def build_ephemeral_schedule_from_params
    raw = params.permit(:frequency, :platform, :post_type, :tone, :auto_approve,
                        :require_photos, :use_logo_fallback,
                        preferred_times: [], preferred_days: [], intent_rotation: [],
                        inventory_statuses: [], image_pool: [], intent_notes: {}).to_h
    return nil if raw[:frequency].blank?
    SocialPostSchedule.new(raw.merge(company_id: @company.id))
  end

  def preview_vehicle(v)
    {
      id: v.id, year: v.year, make: v.make, model: v.model,
      bedrooms: v.try(:bedrooms), bathrooms: v.try(:bathrooms),
      sale_price: v.try(:sale_price), photo_url: v.try(:photo_url),
      stock_number: v.try(:stock_number)
    }
  end

  def serialize(s, detailed: false)
    base = {
      id:                 s.id,
      name:               s.name,
      frequency:          s.frequency,
      active:             s.active,
      auto_approve:       s.auto_approve,
      require_vehicle:    s.require_vehicle,
      require_photos:     s.require_photos,
      inventory_statuses: s.selectable_inventory_statuses,
      image_pool:         Array(s.image_pool),
      use_logo_fallback:  s.use_logo_fallback,
      draft_retention_days: s.draft_retention_days,
      platform:           s.platform,
      post_type:          s.post_type,
      tone:               s.tone,
      preferred_times:    s.preferred_times,
      preferred_days:     s.preferred_days,
      intent_rotation:    s.intent_rotation,
      intent_notes:       s.intent_notes,
      last_generated_at:  s.last_generated_at,
      next_scheduled_at:  s.next_scheduled_at,
      last_intent_used:   s.last_intent_used,
      location_id:        s.location_id,
      intake_form_id:     s.intake_form_id,
      notify_user_id:     s.notify_user_id,
      ends_at:            s.ends_at,
      created_at:         s.created_at,
      updated_at:         s.updated_at
    }
    base
  end
end
