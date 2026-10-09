# frozen_string_literal: true

module Agreements
  # A change to a signed deal (E52 phase 2): once the LIVE Deal Sheet is
  # locked by the signed agreement, the rep makes the change on a draft
  # version and sends the buyers a change order: every line and color that
  # differs, and the contract total before and after. The same people sign
  # it as signed the agreement. Signed, the draft becomes the LIVE version and
  # is locked in its turn; the factory change order (phase 1) then takes the
  # change to the factory.
  class BuyerChangeOrder
    class NotReady < StandardError; end

    def initialize(deal, draft, user:)
      @deal = deal
      @company = deal.company
      @draft = draft
      @live = deal.home_build
      @user = user
    end

    attr_reader :draft, :live

    # The agreement the buyers last signed for the LIVE version: the purchase
    # agreement, or the last change order that made it LIVE.
    def signed
      @signed ||= completed.find do |a|
        a.metadata.to_h.dig('buyer_change_order', 'to_build_id') == @live&.id ||
          (DealSheetLock.purchase?(a) && !DealSheetLock.change_order?(a) && DealSheetLock.stamped_build(a)&.id == @live&.id)
      end
    end

    # One still on its way to the buyers, or nil.
    def open_change_order
      @company.agreements.where(deal_id: @deal.id, status: %w[draft sent viewed partially_signed])
              .find { |a| a.metadata.to_h.dig('buyer_change_order', 'from_build_id') == @live&.id }
    end

    def number
      @company.agreements.where(deal_id: @deal.id).where.not(status: Agreement::STATUS_VOIDED)
              .count { |a| DealSheetLock.change_order?(a) } + 1
    end

    def check
      blocking = []
      blocking << 'The LIVE Deal Sheet is not signed yet: change it directly' unless @live&.locked?
      blocking << 'Make the change on a draft version, not the LIVE one' if @draft.live?
      blocking << 'Nothing differs from the signed version yet' if @live&.locked? && !@draft.live? && changes[:lines].empty? && changes[:colors].empty?
      blocking << 'No signed agreement found for the LIVE version' if @live&.locked? && signed.nil?
      if (open = open_change_order)
        blocking << "Change order #{open.metadata.dig('buyer_change_order', 'number')} (#{open.agreement_number}) is still open: send it, or void it first"
      end
      blocking
    end

    # Lines and colors that differ, and the totals before and after.
    def changes
      @changes ||= begin
        from = keyed(@live)
        to = keyed(@draft)
        lines = []
        (from.keys | to.keys).each do |k|
          a = from[k]
          b = to[k]
          if a.nil?
            lines << row('add', b, nil, b)
          elsif b.nil?
            lines << row('remove', a, a, nil)
          elsif a.quantity.to_d != b.quantity.to_d
            lines << row('quantity', b, a, b)
          elsif price(a) != price(b)
            lines << row('price', b, a, b)
          end
        end
        before = Truebuild::FactoryOrder.colors(@live).index_by { |c| c['set'] }
        colors = Truebuild::FactoryOrder.colors(@draft).filter_map do |c|
          was = before[c['set']]&.dig('choice')
          { 'set' => c['set'], 'from' => was, 'to' => c['choice'] } if was != c['choice'] && c['choice'].present?
        end
        t0 = @live.totals.to_h
        t1 = @draft.totals.to_h
        { lines: lines, colors: colors,
          totals: { 'selling_before' => t0['retail'], 'selling_after' => t1['retail'],
                    'contract_before' => t0['contract_total'], 'contract_after' => t1['contract_total'],
                    'difference' => (t1['contract_total'].to_d - t0['contract_total'].to_d).round(2).to_f,
                    'unpaid_after' => t1['unpaid_balance'] } }
      end
    end

    def create!
      problems = check
      raise NotReady, problems.join('. ') if problems.any?

      n = number
      parent = signed
      signers = parent.agreement_signers.order(:signing_order, :id).to_a
      Agreement.transaction do
        agreement = @company.agreements.create!(
          title: "Change Order #{n}: #{@deal.name}".truncate(250), category: parent.category, content_type: 'pdf_upload',
          agreement_template: parent.agreement_template, deal: @deal, contact: @deal.contact, account: @deal.try(:account),
          location_id: @deal.location_id || parent.location_id, prepared_by: @user, expires_at: 30.days.from_now,
          signing_order: parent.signing_order.presence || 'parallel', status: 'draft', parent_agreement: parent
        )
        labels = signer_labels(parent, signers)
        generator = BuyerChangeOrderPdfGenerator.new(self, number: n, agreement_number: agreement.agreement_number,
                                                           parent_number: parent.agreement_number, signers: labels)
        pdf = generator.generate
        key = "agreements/#{@company.id}/documents/#{agreement.agreement_number}-#{SecureRandom.hex(4)}.pdf"
        document = PrivateFiles.put(pdf, key: key, content_type: 'application/pdf')
        agreement.assign_attributes(document_url: document, document_urls: [document], field_placements: generator.placements,
                                    merge_field_placements: [], custom_field_definitions: [])
        agreement.metadata = agreement.metadata.to_h.merge(
          'buyer_change_order' => { 'number' => n, 'from_build_id' => @live.id, 'to_build_id' => @draft.id,
                                    'parent_agreement_id' => parent.id, 'to_digest' => Agreement.deal_sheet_stamp(@draft)['digest'],
                                    'signer_keys' => self.class.signer_keys(parent),
                                    'difference' => changes[:totals]['difference'] },
          'deal_sheet' => Agreement.deal_sheet_stamp(@draft)
        )
        agreement.save!
        signers.each do |s|
          agreement.agreement_signers.create!(role: s.role, signing_order: s.signing_order, name: s.name, email: s.email, signable: s.signable)
        end
        agreement
      end
    end

    # Everyone signed: the draft becomes the LIVE version, locked. Not
    # repriced: the buyers signed these prices.
    def self.apply!(agreement)
      co = agreement.metadata.to_h['buyer_change_order']
      builds = agreement.company.deal_home_builds
      from = builds.find_by(id: co['from_build_id'])
      to = builds.find_by(id: co['to_build_id'])
      return unless from && to && to.deal_id == agreement.deal_id

      Truebuild::DealBuild.new(to).apply_signed_change!(from: from)
      to
    end

    private

    def completed
      @company.agreements.where(deal_id: @deal.id, status: Agreement::STATUS_COMPLETED).order(completed_at: :desc, id: :desc).to_a
    end

    def keyed(build)
      build.lines.reject { |l| l.kind == 'base' }.index_by { |l| l.catalog_option_id ? "o#{l.catalog_option_id}" : "#{l.kind}:#{l.label.downcase}" }
    end

    def price(line) = line.tbd ? nil : line.retail.to_d.round(2)

    def row(change, line, from, to)
      { 'change' => change, 'description' => line.label, 'code' => line.factory_code,
        'quantity_from' => from&.quantity&.to_d&.to_s('F')&.sub(/\.0\z/, ''), 'quantity_to' => to&.quantity&.to_d&.to_s('F')&.sub(/\.0\z/, ''),
        'price_from' => from && price(from)&.to_f, 'price_to' => to && price(to)&.to_f,
        'delta' => ((to && price(to)).to_d - (from && price(from)).to_d).round(2).to_f }
    end

    # Who signs, by the package's names (buyer_1, rep, ...), carried from
    # the agreement to each change order after it.
    def self.signer_keys(agreement)
      meta = agreement.metadata.to_h
      Array(meta.dig('packet', 'signers').presence || meta.dig('buyer_change_order', 'signer_keys'))
    end

    # "Buyer 1: Pat Smith", in signing order.
    def signer_labels(parent, signers)
      keys = self.class.signer_keys(parent)
      signers.each_with_index.map do |s, i|
        role = PacketRenderer::SIGNER_LABELS[keys[i]] || "Signer #{i + 1}"
        { label: role, name: s.name }
      end
    end
  end
end
