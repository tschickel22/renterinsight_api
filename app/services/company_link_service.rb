# frozen_string_literal: true

# Linking a dealer's vendor to the installer's own company (E68 step 5b).
#
# The dealer invites by the email of an admin at the installer. Any admin with
# that email accepts from inside the installer's company (the company they are
# signed in to, or switched to), and that sets which company the link points
# at. Nothing about the installer is looked up or shown to the dealer before
# then, so an invite can't be used to find out who uses DealerTide.
class CompanyLinkService
  class Error < StandardError; end

  def initialize(company, actor:)
    @company = company
    @actor = actor
  end

  def invite!(vendor:, email:)
    raise Error, 'Pick one of your vendors' unless vendor && vendor.company_id == @company.id
    email = email.to_s.strip.downcase
    raise Error, 'Enter the email of an admin at the installer' unless email.match?(URI::MailTo::EMAIL_REGEXP)
    raise Error, "#{vendor.name} already has a link" if CompanyLink.open.exists?(dealer_vendor_id: vendor.id)

    link = CompanyLink.create!(dealer_company: @company, dealer_vendor: vendor, invite_email: email, invited_by: @actor,
                               agreement_version: CompanyLink::AGREEMENT_VERSION, dealer_agreed_at: Time.current)
    link.log!('invited', "#{@company.name} invited #{email} to link as #{vendor.name}", company: @company, user: @actor)
    CompanyLinkNotifier.invited(link)
    link
  end

  # Invitations waiting for an admin of this company: sent to their email,
  # not yet accepted, from another company.
  def invitations_for_me
    return CompanyLink.none unless @actor&.effective_admin?

    CompanyLink.where(status: 'invited', invite_email: @actor.email.to_s.downcase).where.not(dealer_company_id: @company.id)
  end

  def accept!(link)
    raise Error, 'Only an admin can accept a link' unless @actor&.effective_admin?
    raise Error, 'This invitation is not for you' unless invitations_for_me.exists?(id: link.id)
    if CompanyLink.where(dealer_company_id: link.dealer_company_id, installer_company_id: @company.id).where.not(id: link.id).exists?
      raise Error, "#{link.dealer_company.name} is already linked with #{@company.name}"
    end

    ActiveRecord::Base.transaction do
      link.update!(installer_company: @company, status: 'active', accepted_by: @actor, accepted_at: Time.current,
                   installer_agreed_at: Time.current, installer_dealer_account: dealer_as_customer(link.dealer_company))
      link.log!('accepted', "#{@company.name} accepted the link", company: @company, user: @actor)
    end
    CompanyLinkNotifier.accepted(link)
    link
  end

  def end!(link, reason: nil)
    raise Error, 'Not your link' unless link.side_for(@company) || (link.invited? && invitations_for_me.exists?(id: link.id))
    raise Error, 'This link has already ended' if link.status == 'ended'

    ActiveRecord::Base.transaction do
      link.update!(status: 'ended', ended_at: Time.current, ended_by: @actor)
      link.log!('ended', ["#{@company.name} ended the link", reason.presence].compact.join(': '), company: @company, user: @actor)
    end
    CompanyLinkNotifier.ended(link, by: @company)
    link
  end

  private

  # The dealer as a customer account of the installer, so the installer can
  # invoice it. An existing account with the same name is reused.
  def dealer_as_customer(dealer)
    @company.accounts.find_or_create_by!(name: dealer.name) do |a|
      a.account_type = 'customer'
      a.status = 'active'
      a.email = dealer.try(:email)
      a.phone = dealer.try(:phone)
    end
  end
end
