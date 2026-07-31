# frozen_string_literal: true

# Called from the workflow engine when a rule fires a social-post action.
# Produces a draft SocialPost (or auto-approved, depending on the company's
# primary schedule), and if auto-approved, triggers publish via the standard
# Meta path. If not auto-approved, an approval email is dispatched.
class GenerateWorkflowSocialPostJob < ApplicationJob
  queue_as :default

  TRIGGER_TO_INTENT = {
    'sold_celebration' => 'social_proof',
    'new_arrival'      => 'new_arrival',
    'aged_inventory'   => 'aged_inventory'
  }.freeze

  def perform(company_id:, trigger_type:, entity_id:, entity_type:)
    company = Company.find_by(id: company_id)
    return Rails.logger.warn("[GenerateWorkflowSocialPostJob] no company=#{company_id}") unless company

    entity = resolve_entity(entity_type, entity_id, company)
    return Rails.logger.warn("[GenerateWorkflowSocialPostJob] no entity #{entity_type}##{entity_id}") unless entity

    intent = TRIGGER_TO_INTENT[trigger_type.to_s]
    return Rails.logger.warn("[GenerateWorkflowSocialPostJob] unknown trigger=#{trigger_type}") if intent.blank?

    vehicle = resolve_vehicle(entity)
    schedule = primary_schedule_for(company)

    intake_form = company.intake_forms.order(:id).first if company.respond_to?(:intake_forms)

    # Resolved before generating so the copy describes the picture that ships
    # with it, rather than being written blind and having images bolted on.
    images = extract_images(vehicle)

    result = SocialPostGeneratorService.generate(
      company:         company,
      intent_category: intent,
      post_type:       schedule&.post_type  || 'company_page',
      platform:        schedule&.platform   || 'facebook',
      vehicle:         vehicle,
      tone:            schedule&.tone       || 'friendly',
      intake_form_url: intake_form&.public_url,
      # Only the first image publishes, so it is the only one to describe.
      image_urls:      images.first(1)
    )

    post = SocialPost.create!(
      company_id:            company.id,
      location_id:           schedule&.location_id,
      vehicle_id:            vehicle&.id,
      post_type:             schedule&.post_type  || 'company_page',
      intent_category:       intent,
      platform:              schedule&.platform   || 'facebook',
      status:                'draft',
      caption:               result[:caption],
      headline:              result[:headline],
      description:           result[:description],
      cta_type:              result[:cta_type],
      image_urls:            images,
      utm_campaign:          intent,
      ai_generation_version: result[:ai_generation_version],
      generation_context:    (result[:generation_context] || {}).merge(
        'hashtags'     => Array(result[:hashtags]),
        'trigger_type' => trigger_type,
        'entity_type'  => entity_type,
        'entity_id'    => entity_id
      ).compact
    )

    if schedule&.auto_approve
      post.update!(status: 'approved', approved_at: Time.current, nurture_approved: true)
    else
      send_approval_email(post, company, schedule)
    end

    post
  rescue => e
    Rails.logger.error "[GenerateWorkflowSocialPostJob] failed: #{e.class}: #{e.message}"
    raise
  end

  private

  def resolve_entity(type, id, company)
    case type.to_s
    when 'Vehicle' then company.vehicles.where(is_deleted: false).find_by(id: id)
    when 'Deal'    then Deal.find_by(id: id)
    when 'Lead'    then company.leads.find_by(id: id)
    else                Object.const_get(type.to_s).find_by(id: id) rescue nil
    end
  end

  def resolve_vehicle(entity)
    return entity if entity.is_a?(Vehicle)
    return Vehicle.find_by(id: entity.vehicle_id) if entity.respond_to?(:vehicle_id) && entity.vehicle_id.present?
    nil
  end

  def primary_schedule_for(company)
    company.social_post_schedules.active.order(:id).first
  end

  def extract_images(vehicle)
    return [] unless vehicle
    imgs = []
    imgs << vehicle.photo_url if vehicle.respond_to?(:photo_url) && vehicle.photo_url.present?
    Array(vehicle.try(:images)).each do |img|
      url = img.is_a?(Hash) ? (img['url'] || img[:url]) : img
      imgs << url if url.present?
    end
    imgs.uniq.first(10)
  end

  def send_approval_email(post, company, schedule)
    recipient = schedule&.notify_user ||
                User.where(company_id: company.id, role: 'admin').order(:id).first ||
                User.where(company_id: company.id).order(:id).first
    return unless recipient&.email.present?
    SocialPostMailer.approval_needed(post, recipient).deliver_later
  rescue => e
    Rails.logger.error "[GenerateWorkflowSocialPostJob] approval email failed: #{e.message}"
  end
end
