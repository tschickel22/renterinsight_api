# frozen_string_literal: true

# The installer's rate card for a linked dealer (E68 step 6): the installer
# sends a version, the dealer approves or declines it. The approved version
# stays in force until the dealer approves a newer one.
class LinkRateCardService
  class Error < StandardError; end

  def initialize(company, actor:)
    @company = company
    @actor = actor
  end

  # Installer side. Replaces a version still waiting for the dealer.
  def submit!(link, items:, note: nil)
    raise Error, 'Not your link' unless link.installer_company_id == @company.id
    raise Error, 'The link has ended' unless link.active?

    card = nil
    ActiveRecord::Base.transaction do
      link.lock!
      link.rate_cards.submitted.find_each { |c| c.update!(status: 'withdrawn') }
      card = link.rate_cards.create!(version: (link.rate_cards.maximum(:version) || 0) + 1, status: 'submitted',
                                     items: Array(items).map { |i| i.to_h.deep_stringify_keys },
                                     note: note.presence, submitted_by: @actor)
      link.log!('rate_card_submitted', "#{@company.name} sent rate card version #{card.version}", company: @company, user: @actor,
                data: { rate_card_id: card.id, lines: card.items.size })
    end
    CompanyLinkNotifier.rate_card_submitted(card)
    card
  end

  def withdraw!(card)
    raise Error, 'Not your rate card' unless card.company_link.installer_company_id == @company.id
    raise Error, 'Only a card waiting for the dealer can be withdrawn' unless card.submitted?

    card.update!(status: 'withdrawn')
    card.company_link.log!('rate_card_withdrawn', "#{@company.name} withdrew rate card version #{card.version}", company: @company, user: @actor)
    card
  end

  # Dealer side.
  def approve!(card)
    link = check_dealer!(card)
    ActiveRecord::Base.transaction do
      link.lock!
      link.rate_cards.approved.where.not(id: card.id).find_each { |c| c.update!(status: 'superseded') }
      card.update!(status: 'approved', decided_by: @actor, decided_at: Time.current)
      link.log!('rate_card_approved', "#{@company.name} approved rate card version #{card.version}", company: @company, user: @actor,
                data: { rate_card_id: card.id })
    end
    CompanyLinkNotifier.rate_card_decided(card)
    card
  end

  def decline!(card, reason: nil)
    link = check_dealer!(card)
    card.update!(status: 'declined', decided_by: @actor, decided_at: Time.current, decline_reason: reason.presence)
    link.log!('rate_card_declined', ["#{@company.name} declined rate card version #{card.version}", reason.presence].compact.join(': '),
              company: @company, user: @actor, data: { rate_card_id: card.id })
    CompanyLinkNotifier.rate_card_decided(card)
    card
  end

  private

  def check_dealer!(card)
    link = card.company_link
    raise Error, 'Not your link' unless link.dealer_company_id == @company.id
    raise Error, 'The link has ended' unless link.active?
    raise Error, 'This rate card is not waiting for you' unless card.submitted?

    link
  end
end
