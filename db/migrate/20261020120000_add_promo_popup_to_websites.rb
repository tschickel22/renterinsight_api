# frozen_string_literal: true

# A dated flyer and video that greets a site's visitors (an open house, a sale)
# until they choose Enter Site. See Websites::PromoPopup.
class AddPromoPopupToWebsites < ActiveRecord::Migration[8.0]
  def change
    add_column :websites, :promo_popup, :jsonb, default: {}, null: false
  end
end
