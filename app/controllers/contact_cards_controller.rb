# frozen_string_literal: true

# GET /vc/:token, a rep's contact card for a lead to save. Public: the token is
# the authorization (see ContactCard).
class ContactCardsController < ActionController::API
  def show
    user = ContactCard.user_for(params[:token])
    return head :not_found if user.nil?

    send_data ContactCard.vcard(user),
              type: 'text/vcard; charset=utf-8',
              filename: ContactCard.filename(user),
              disposition: 'attachment'
  end
end
