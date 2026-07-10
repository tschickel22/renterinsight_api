module Messaging
  # Resolves the "signature" / CTA block contact info shown at the bottom of
  # the email. Cascade is sender-first: rep → their location (or campaign
  # location) → company. Independent of BrandingResolver because a rep
  # sending from a different location than the recipient still shows THAT
  # rep's contact info (that's who the reply lands with).
  #
  # sender_user is nil for Location/Company from_identity_type — falls
  # through directly to the location/company chain.
  class ContactResolver
    def initialize(sender_user:, campaign:, company:, recipient: nil)
      @sender_user = sender_user
      @campaign    = campaign
      @company     = company
      @recipient   = recipient
    end

    def resolve
      loc = sender_location || @campaign.try(:location) || recipient_location

      {
        name:        pick(:name),
        title:       @sender_user.try(:title),
        email:       pick(:email),
        phone:       pick(:phone),
        address:     loc&.full_address.presence || company_full_address,
        booking_url: @sender_user.try(:booking_url).presence,
        location_name: loc&.name.presence || @company.name,
        signature:   @sender_user.try(:typed_signature).presence
      }
    end

    private

    # Field-by-field fallback so a rep with only email set still gets a
    # complete card (location phone, company address, etc.).
    # Location cascade: sender's home location → campaign's scoped location
    # → recipient's location → company. Skipping campaign location here
    # produced Company-branded CTAs on Location-type sends.
    def pick(field)
      loc = sender_location || @campaign.try(:location) || recipient_location
      case field
      when :name
        user_full_name.presence || loc&.name.presence || @company.name
      when :email
        @sender_user.try(:email).presence || loc&.email.presence || @company.try(:email)
      when :phone
        @sender_user.try(:phone).presence || loc&.phone.presence || @company.try(:phone)
      end
    end

    def user_full_name
      return nil unless @sender_user
      full = "#{@sender_user.try(:first_name)} #{@sender_user.try(:last_name)}".strip
      full.presence || @sender_user.try(:name)
    end

    # Users have primary_location_id or a UserLocation join — try both
    # patterns so this works across the tenants that migrated at different
    # times.
    def sender_location
      return nil unless @sender_user
      @sender_location ||=
        @sender_user.try(:primary_location) ||
        @sender_user.try(:location) ||
        (@sender_user.try(:locations)&.first)
    end

    def recipient_location
      @recipient.respond_to?(:location) ? @recipient.location : nil
    end

    def company_full_address
      parts = [
        @company.try(:address_line1),
        @company.try(:address_line2),
        @company.try(:city),
        @company.try(:state),
        @company.try(:zip_code)
      ].map(&:presence).compact
      parts.any? ? parts.join(', ') : nil
    end
  end
end
