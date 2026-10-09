# frozen_string_literal: true

module Truebuild
  # A design saved by a buyer who has an open deal reaches that deal for the
  # rep to review (plan item 7). When the deal has a Deal Sheet, the design
  # becomes a new draft version ("From the buyer's design, Oct 9"), never the
  # LIVE one; when it has none, the design is attached so the sheet offers to
  # start from it. Either way the deal's rep is told.
  module DesignToDeal
    module_function

    # => the draft DealHomeBuild, the deal (no sheet yet), or nil
    def call(design)
      return nil if design.deal_id.present? || design.variant.nil?

      deal = open_deal_for(design)
      return nil unless deal

      design.update_columns(deal_id: deal.id, updated_at: Time.current)
      if deal.home_builds.exists?
        label = "From the buyer's design, #{Time.current.in_time_zone(deal.company.time_zone).strftime('%b %-d')}"
        build = DealBuild.start(deal: deal, variant: design.variant, vehicle: design.vehicle, design: design, label: label).build
        notify(deal, design, "#{design.buyer_name.presence || 'The buyer'} saved a design: it is #{build.version_name} on the Deal Sheet, a draft to review.")
        build
      else
        notify(deal, design, "#{design.buyer_name.presence || 'The buyer'} saved a design. Start the Deal Sheet from it.")
        deal
      end
    end

    # The buyer's newest open deal: by the design's contact, else a contact of
    # the dealer with the buyer's email.
    def open_deal_for(design)
      company = design.company
      contact = design.contact
      contact ||= company.contacts.where('LOWER(email) = ?', design.buyer_email.to_s.downcase).first if design.buyer_email.present?
      return nil unless contact

      company.deals.active.where(contact_id: contact.id).order(updated_at: :desc).find(&:open?)
    end

    def notify(deal, design, message)
      recipient = deal.owner || deal.user
      return unless recipient

      NotificationService.create(
        recipient: recipient, notification_type: :deal_sheet_buyer_design, notifiable: deal,
        title: 'A buyer saved a design', message: message,
        action_url: "/deals/#{deal.id}?tab=home_build", action_text: 'Open the Deal Sheet',
        company_id: deal.company_id, location_id: deal.location_id, metadata: { 'truebuild_design_id' => design.id }
      )
    rescue StandardError => e
      Rails.logger.warn("[DesignToDeal] notice for deal #{deal.id}: #{e.message}")
    end
  end
end
