# frozen_string_literal: true

module Truebuild
  # The platform admin's answer to a dealer's option change (backlog E85,
  # CatalogOptionRequest):
  #
  #   apply!        for every dealer: an added color joins the factory's book,
  #                 a hidden color is retired, a new name becomes the book's
  #   keep!         for that dealer only; it goes on working for them
  #   dismiss!      turned down: the dealer's change is undone
  #
  # The dealer is told only when their change is turned down (it stops
  # working for them); whether it went to every dealer is not theirs to
  # follow (Tom, 2026-10-22). Open Deal Sheets reprice when next opened
  # (DealBuild.stale?); signed ones never change.
  class OptionRequests
    class Invalid < StandardError; end

    def initialize(request, user:)
      @request = request
      @user = user
    end

    # Also from dealer_only: kept for one dealer, then made everyone's.
    def apply!(note: nil)
      raise Invalid, "This request is #{@request.status}" unless CatalogOptionRequest::IN_FORCE.include?(@request.status)

      option = @request.option
      CatalogOptionRequest.transaction do
        case @request.action
        when 'add' then publish_color!(option)
        when 'hide' then option.update!(status: 'discontinued', discontinued_on: Date.current)
        when 'rename' then option.update!(name: @request.name)
        end
        resolve!('applied', note)
      end
    end

    def keep!(note: nil)
      open!
      resolve!('dealer_only', note)
    end

    def dismiss!(note: nil)
      raise Invalid, "This request is #{@request.status}" unless CatalogOptionRequest::IN_FORCE.include?(@request.status)

      CatalogOptionRequest.transaction do
        # Turning down a color takes it off the dealer's lists; picks already made stay.
        @request.option.update!(status: 'discontinued', discontinued_on: Date.current) if @request.action == 'add' && @request.option.dealer_color?
        resolve!('dismissed', note)
      end
      notify('Change undone', "#{@request.label}: undone, the factory's is back.#{note.present? ? " #{note}" : ''}")
    end

    private

    def open!
      raise Invalid, "This request is #{@request.status}" unless @request.status == 'open'
    end

    # The dealer's color becomes the factory's: no longer theirs alone, and
    # priced in every published book that prices its set, for the same homes
    # as the set's other colors.
    def publish_color!(option)
      set = option.metadata.to_h['color_set']
      siblings = CatalogOption.platform.where(manufacturer_id: option.manufacturer_id, kind: 'color')
                              .where("metadata->>'color_set' = ?", set).select(:id)
      rows = CatalogOptionPrice.joins(:price_book).merge(CatalogPriceBook.published).where(catalog_option_id: siblings).to_a
      raise Invalid, "No published book prices the #{set} colors" if rows.empty?

      meta = option.metadata.to_h
      cost = meta['cost'].presence&.to_d
      option.update!(company_id: nil)
      fields = %i[catalog_price_book_id catalog_plan_variant_id series min_length_ft max_length_ft width_ft section_type construction building_code]
      rows.uniq { |r| fields.map { |f| r[f] } }.each do |r|
        CatalogOptionPrice.create!(r.attributes.slice(*fields.map(&:to_s)).merge(
          'catalog_option_id' => option.id, 'is_standard' => cost.nil? || cost.zero?, 'dealer_cost' => cost,
          'suggested_retail' => meta['retail'].presence&.to_d, 'source_ref' => { 'dealer_request_id' => @request.id }
        ))
      end
      CatalogPriceBook.where(id: rows.map(&:catalog_price_book_id).uniq).find_each do |book|
        book.update!(metadata: book.metadata.to_h.merge('corrected_at' => Time.current.iso8601(6)))
      end
    end

    def resolve!(status, note)
      @request.update!(status: status, resolved_by: @user, resolved_at: Time.current, resolution_note: note.presence)
    end

    # Best-effort: the request is decided either way.
    def notify(title, message)
      return unless @request.requested_by

      NotificationService.create(
        recipient: @request.requested_by, notification_type: :truebuild_price_request, notifiable: @request,
        company_id: @request.company_id, title: title, message: message,
        action_url: @request.deal_id ? "/deals/#{@request.deal_id}?tab=home_build" : '/settings?tab=truebuild',
        action_text: @request.deal_id ? 'Open the deal' : 'Open your price list'
      )
    rescue StandardError => e
      Rails.logger.error("[OptionRequest] notify #{@request.id}: #{e.class} #{e.message}")
    end
  end
end
