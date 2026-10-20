# frozen_string_literal: true

# The popup a website shows visitors on arrival (flyer, video, dates). One per
# site, read and replaced whole. See Websites::PromoPopup.
class Api::V1::WebsitePromoPopupsController < ApplicationController
  before_action :set_company_scope
  before_action :set_website

  # GET /api/v1/websites/:website_id/promo_popup
  def show
    return unless authorize_action!('websites', 'read')

    render json: popup_json
  end

  # PUT /api/v1/websites/:website_id/promo_popup
  # Params: promo_popup: { enabled, image_url, video_url, headline, enter_label,
  #                        directions_address, start_date, end_date }
  def update
    return unless authorize_action!('websites', 'update')

    raw = params.fetch(:promo_popup, {}).permit(*Websites::PromoPopup::FIELDS)
    @website.update!(promo_popup: Websites::PromoPopup.normalize(raw))
    render json: popup_json
  rescue Websites::PromoPopup::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_website
    # CRITICAL: Always use @company scope
    @website = @company.websites.find(params[:website_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Website not found' }, status: :not_found
  end

  def popup_json
    {
      promo_popup: @website.promo_popup.to_h,
      default_enter_label: Websites::PromoPopup::DEFAULT_ENTER_LABEL,
      default_directions_address: Websites::PromoPopup.default_address(@website),
      time_zone: Websites::PromoPopup.time_zone(@website)
    }
  end
end
