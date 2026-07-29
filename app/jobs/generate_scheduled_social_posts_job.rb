# frozen_string_literal: true

# Hourly job that consumes due SocialPostSchedule rows and generates posts.
# Safe to run frequently — it only picks up schedules whose next_scheduled_at
# is due now.
class GenerateScheduledSocialPostsJob < ApplicationJob
  queue_as :default

  def perform
    generated = 0
    failed    = 0

    SocialPostSchedule.due.find_each do |schedule|
      begin
        generate_for(schedule)
        generated += 1
      rescue => e
        failed += 1
        Rails.logger.error "[GenerateScheduledSocialPostsJob] schedule=#{schedule.id} failed: #{e.class}: #{e.message}"
      end
    end

    Rails.logger.info "[GenerateScheduledSocialPostsJob] generated=#{generated} failed=#{failed}"
  end

  private

  def generate_for(schedule)
    company = schedule.company
    intent  = ScheduleIntentPicker.next(rotation: schedule.intent_rotation, last: schedule.last_intent_used)
    vehicle = pick_vehicle(schedule, intent)

    if schedule.require_vehicle && vehicle.nil? && vehicle_required_for_intent?(company, intent)
      # A one-time schedule's next run is its fixed run_at, so rescheduling it
      # would re-fire every tick forever. Retire it instead.
      return schedule.one_time? ? retire(schedule, last_intent: intent)
                                : reschedule(schedule, last_intent: intent, reason: 'no_vehicle_available')
    end

    intake_form = resolve_intake_form(schedule)

    # User's per-intent idea wins; else seasonal auto-topic; else context-only (today's behavior).
    user_note = (schedule.intent_notes || {})[intent].presence
    topic_details = user_note || (intent == 'seasonal' ? SeasonalContentService.topic_for_seasonal_post : nil)

    # Resolve the images first so the model can see what will actually run
    # alongside the copy. Generating first and attaching afterwards produced
    # posts whose caption had nothing to do with the picture.
    #
    # Note this advances the image pool cursor, so it must happen exactly once
    # per run — build_post_from_result takes the result rather than re-resolving.
    images = resolve_images(schedule, vehicle)

    result = SocialPostGeneratorService.generate(
      company:         company,
      intent_category: intent,
      post_type:       schedule.post_type,
      platform:        schedule.platform,
      vehicle:         vehicle,
      user:            schedule.notify_user,
      tone:            schedule.tone,
      intake_form_url: intake_form&.public_url,
      topic_details:   topic_details,
      # Only the first image is published — there is no carousel support — so
      # that is the only one worth describing. Feeding the model all ten of a
      # home's photos had it writing about details nobody would ever see.
      image_urls:      images.first(1)
    )

    post = build_post_from_result(schedule, intent, vehicle, intake_form, result, images)
    post.save!

    post.update_columns(
      utm_content: post.id.to_s,
      tagged_url:  build_tagged_url(intake_form, post, result)
    )

    # One-time schedules approve like any other. The post is AI-generated at run
    # time, so the user has not seen it — scheduling it is not approving it.
    if schedule.auto_approve
      post.update!(status: 'approved', approved_at: Time.current, nurture_approved: true)
      PublishSocialPostJob.perform_later(post.id)
    else
      send_approval_email(post, schedule)
    end

    if schedule.one_time?
      retire(schedule, last_intent: intent)
    else
      reschedule(schedule, last_intent: intent, last_generated: true)
    end
    post
  end

  # A schedule the user pinned to a specific unit features that unit, full stop.
  # Everything else draws from inventory per the schedule's status/photo rules.
  def pick_vehicle(schedule, intent)
    if schedule.vehicle_id.present?
      pinned = schedule.company.vehicles.where(is_deleted: false).find_by(id: schedule.vehicle_id)
      return pinned if pinned
    end
    SchedulePreviewVehiclePicker.pick_for(schedule, intent: intent)
  end

  def build_post_from_result(schedule, intent, vehicle, intake_form, result, images)
    caption, headline, description = result.values_at(:caption, :headline, :description)
    hashtags = Array(result[:hashtags])

    SocialPost.new(
      company_id:            schedule.company_id,
      location_id:           schedule.location_id,
      created_by_user_id:    schedule.notify_user_id,
      vehicle_id:            vehicle&.id,
      post_type:             schedule.post_type,
      intent_category:       intent,
      platform:              schedule.platform,
      status:                'draft',
      caption:               caption,
      headline:              headline,
      description:           description,
      image_urls:            images,
      cta_type:              result[:cta_type],
      utm_campaign:          intent,
      ai_generation_version: result[:ai_generation_version],
      generation_context:    (result[:generation_context] || {}).merge(
        'hashtags'     => hashtags,
        'schedule_id'  => schedule.id,
        'intent_pick'  => intent,
        'intake_form_id' => intake_form&.id,
        'ad_settings'  => result[:ad_settings]
      ).compact
    )
  end

  # Images for a generated post, most-specific source first:
  #   1. photos on the featured unit
  #   2. the schedule's image pool, rotated so repeat posts don't reuse one image
  #   3. the company logo, but only if the schedule opted in
  # When none of those produce anything the post stays imageless by design —
  # we never invent an image for a listing.
  def resolve_images(schedule, vehicle)
    from_vehicle = extract_vehicle_images(vehicle)
    return from_vehicle if from_vehicle.any?

    pooled = schedule.next_pool_image!
    return [pooled] if pooled.present?

    return [] unless schedule.use_logo_fallback

    logo = schedule.company.try(:logo)
    logo.present? ? [logo] : []
  end

  def extract_vehicle_images(vehicle)
    return [] unless vehicle
    images = []
    images << vehicle.try(:photo_url) if vehicle.respond_to?(:photo_url) && vehicle.photo_url.present?
    Array(vehicle.try(:images)).each do |img|
      url = img.is_a?(Hash) ? (img['url'] || img[:url]) : img
      images << url if url.present?
    end
    images.uniq.first(10)
  end

  def build_tagged_url(intake_form, post, result)
    base = intake_form&.public_url
    return nil if base.blank?

    uri = URI.parse(base)
    existing = URI.decode_www_form(uri.query.to_s).to_h
    merged = existing.merge(
      'utm_source'   => (post.platform || 'facebook').to_s,
      'utm_medium'   => 'social',
      'utm_campaign' => post.intent_category.to_s,
      'utm_content'  => post.id.to_s
    )
    uri.query = URI.encode_www_form(merged.reject { |_, v| v.to_s.blank? })
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def resolve_intake_form(schedule)
    return IntakeForm.find_by(id: schedule.intake_form_id, company_id: schedule.company_id) if schedule.intake_form_id.present?
    schedule.company.intake_forms.order(:id).first if schedule.company.respond_to?(:intake_forms)
  end

  def vehicle_required_for_intent?(company, intent)
    SocialPostIntentCatalog.for_company(company).requires_subject?(intent)
  end

  def send_approval_email(post, schedule)
    recipient = schedule.notify_user || default_approver_for(schedule.company)
    return unless recipient&.email.present?
    SocialPostMailer.approval_needed(post, recipient).deliver_later
  rescue => e
    Rails.logger.error "[GenerateScheduledSocialPostsJob] approval email failed: #{e.message}"
  end

  def default_approver_for(company)
    User.where(company_id: company.id, role: 'admin').order(:id).first ||
      User.where(company_id: company.id).order(:id).first
  end

  # A one-time schedule has done its job. Deactivate rather than delete so the
  # user can still see what ran and when.
  def retire(schedule, last_intent:)
    schedule.update_columns(
      active:            false,
      next_scheduled_at: nil,
      last_intent_used:  last_intent,
      last_generated_at: Time.current
    )
    Rails.logger.info "[GenerateScheduledSocialPostsJob] schedule=#{schedule.id} one_time fired, deactivated"
  end

  def reschedule(schedule, last_intent:, last_generated: false, reason: nil)
    next_at = schedule.calculate_next_scheduled_at(from: Time.current)
    updates = { next_scheduled_at: next_at, last_intent_used: last_intent }
    updates[:last_generated_at] = Time.current if last_generated
    schedule.update_columns(updates)
    Rails.logger.info "[GenerateScheduledSocialPostsJob] schedule=#{schedule.id} next=#{next_at} reason=#{reason || 'ok'}"
  end
end
