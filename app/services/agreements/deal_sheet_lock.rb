# frozen_string_literal: true

module Agreements
  # The Deal Sheet and its signed agreement (step 5 of the agreement plan):
  # a purchase agreement made from the Deal Sheet locks the version it was
  # made from once everyone has signed, and from then on the sheet changes
  # only by a change order the buyers sign (BuyerChangeOrder). A signed
  # agreement cannot be voided, so a locked version stays locked. An
  # agreement whose sheet has changed since it was made cannot be sent: the
  # buyers would sign numbers the deal no longer has.
  class DealSheetLock
    class << self
      # A purchase agreement: made with Create agreement, or from a purchase
      # agreement template. Other paperwork on a deal does not lock the sheet.
      def purchase?(agreement)
        agreement.metadata.to_h['packet'].present? || agreement.agreement_template&.form_type == 'purchase_agreement'
      end

      def change_order?(agreement) = agreement.metadata.to_h['buyer_change_order'].present?

      # Called once the agreement is completed.
      def completed(agreement)
        return BuyerChangeOrder.apply!(agreement) if change_order?(agreement)
        return unless purchase?(agreement)

        build = stamped_build(agreement)
        build&.update!(status: 'locked')
        build
      end

      # Why it cannot be sent, or nil.
      def send_problem(agreement)
        if change_order?(agreement)
          co = agreement.metadata.to_h['buyer_change_order']
          live = agreement.deal&.home_build
          to = agreement.company.deal_home_builds.find_by(id: co['to_build_id'])
          return 'The version this change order would make LIVE is gone. Void it and make a new one.' unless to
          return 'The LIVE Deal Sheet is no longer the one this change order changes. Void it and make a new one.' unless live&.id == co['from_build_id']
          return "#{to.version_name} has changed since this change order was made. Void it and make a new one." if Agreement.deal_sheet_stamp(to)['digest'] != co['to_digest']

          return nil
        end
        return nil unless purchase?(agreement)

        status = agreement.deal_sheet_status
        return nil unless status

        if !status[:live] || status[:changed]
          "The Deal Sheet has changed since this agreement was made (now #{status[:live_version_name]}). " \
            'Make a new agreement from the Deal Sheet so the buyer signs what is on it.'
        end
      end

      def stamped_build(agreement)
        id = agreement.metadata.to_h.dig('deal_sheet', 'build_id')
        id && agreement.company.deal_home_builds.find_by(id: id)
      end
    end
  end
end
