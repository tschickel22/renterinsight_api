# frozen_string_literal: true

module Agreements
  # Create agreement, from the Deal Sheet: the dealer's agreement package
  # rendered for this deal (PacketRenderer), stored as the agreement's
  # document, with its signing fields placed, the rep's fields to fill, and
  # the signers taken from the deal: the buyers, the rep, and the manager who
  # accepts it. A draft: the rep reviews it and sends it from the agreement.
  # It records the Deal Sheet version it was made from.
  class FromDealSheet
    class NotReady < StandardError; end

    def initialize(deal, user:)
      @deal = deal
      @company = deal.company
      @user = user
    end

    # The dealer's packages, newest first.
    def templates
      @company.agreement_templates.where(is_deleted: false, status: 'active').order(updated_at: :desc).select(&:packet?)
    end

    # Who can accept it for the dealer: the company's people, not removed.
    def managers
      @company.users.where(deleted_at: nil).where.not(status: %w[inactive suspended deactivated]).order(:first_name, :last_name)
              .map { |u| { id: u.id, name: u.full_name, email: u.email } }
    end

    # What stops it being sent, in words the rep acts on. Blocking items stop
    # Create; the rest are listed so the rep can fix them first or after.
    def check(manager: nil)
      blocking = []
      blocking << 'Start the Deal Sheet first' unless @deal.home_build
      blocking << 'Add the buyer to the deal' unless @deal.contact
      blocking << 'The buyer needs an email address to sign' if @deal.contact && @deal.contact.email.blank?
      blocking << 'Buyer 2 needs an email address to sign' if @deal.co_applicant_contact && @deal.co_applicant_contact.email.blank?
      blocking << 'Choose the manager who accepts the agreement' if manager_required? && manager.nil?
      blocking << 'Set up the agreement package first' if templates.empty?
      open = DealSaleDetails.new(@deal).missing.map { |m| "Deal Sheet: #{m}" }
      open += Truebuild::AgreementSheets.new(@deal.home_build).open_items if @deal.home_build
      { blocking: blocking, open: open }
    end

    def create!(template:, manager: nil)
      problems = check(manager: manager)[:blocking]
      raise NotReady, problems.join('. ') if problems.any?
      raise NotReady, 'That is not an agreement package' unless template.packet?

      Agreement.transaction do
        agreement = @company.agreements.create!(
          title: "#{template.name}: #{@deal.name}".truncate(250), description: template.description,
          category: template.category, agreement_template: template, content_type: 'upload',
          deal: @deal, contact: @deal.contact, account: @deal.try(:account), location_id: @deal.location_id || Current.location_id,
          prepared_by: @user, expires_at: 30.days.from_now, signing_order: 'parallel', status: 'draft'
        )
        result = PacketRenderer.new(@deal, template, agreement_number: agreement.agreement_number).call
        key = "agreements/#{@company.id}/documents/#{agreement.agreement_number}-#{SecureRandom.hex(4)}.pdf"
        agreement.assign_attributes(document_url: PrivateFiles.put(result.pdf, key: key, content_type: 'application/pdf'),
                                    field_placements: result.placements, merge_field_placements: [],
                                    custom_field_definitions: result.definitions)
        agreement.metadata = agreement.metadata.to_h.merge('packet' => { 'page_count' => result.page_count, 'signers' => result.signers })
        agreement.stamp_deal_sheet!
        agreement.save!
        result.signers.each { |key_name| add_signer(agreement, key_name, manager) }
        agreement
      end
    end

    private

    def manager_required? = templates.any? { |t| Array(t.packet['signers']).include?('manager') }

    def add_signer(agreement, key, manager)
      who = case key
            when 'buyer_1' then @deal.contact
            when 'buyer_2' then @deal.co_applicant_contact
            when 'rep' then @deal.owner || @user
            when 'manager' then manager
            end
      return unless who

      name = who.respond_to?(:full_name) && who.full_name.present? ? who.full_name : [who.try(:first_name), who.try(:last_name)].compact.join(' ')
      agreement.agreement_signers.create!(role: 'signer', signing_order: 1,
                                          name: name.presence || who.email, email: who.email, signable: who)
    end
  end
end
