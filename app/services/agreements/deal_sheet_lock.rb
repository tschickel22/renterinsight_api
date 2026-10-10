# frozen_string_literal: true

module Agreements
  # The Deal Sheet and its signed agreement (step 5 of the agreement plan):
  # a purchase agreement made from the Deal Sheet locks the version it was
  # made from once everyone has signed, and from then on the sheet changes
  # only by a change order the buyers sign (BuyerChangeOrder). When the
  # deal has to be redone instead, a manager can unlock the LIVE version with
  # a reason (unlock!): the signed agreement stays as signed, its badge then
  # shows the sheet has changed, and a new agreement is made and signed. An
  # agreement whose sheet has changed since it was made cannot be sent: the
  # buyers would sign numbers the deal no longer has.
  class DealSheetLock
    ACTION_UNLOCKED = 'deal_sheet_unlocked'

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

      # The signed LIVE version opens for changes again. The agreement that
      # locked it stays completed; the unlock is recorded on it and on the
      # version, with who and why.
      def unlock!(build, user:, reason:)
        reason = reason.to_s.strip
        raise ArgumentError, 'Say why the signed Deal Sheet is being unlocked' if reason.blank?
        raise ArgumentError, 'This version is not locked' unless build.locked?
        raise ArgumentError, 'Only the LIVE version can be unlocked; older signed versions stay as they were' unless build.live?

        signed = signed_agreement(build)
        entry = { 'at' => Time.current.iso8601, 'by_id' => user&.id, 'by' => user&.full_name, 'reason' => reason.truncate(500),
                  'agreement_id' => signed&.id, 'agreement_number' => signed&.agreement_number }
        DealHomeBuild.transaction do
          build.update!(status: 'draft', metadata: build.metadata.to_h.merge('unlocks' => Array(build.metadata.to_h['unlocks']) + [entry]))
          if signed
            signed.update!(metadata: signed.metadata.to_h.merge('deal_sheet_unlocked' => entry))
            AgreementAuditLog.log!(signed, ACTION_UNLOCKED, performed_by: user,
                                                            metadata: { reason: entry['reason'], build_id: build.id, version: build.version_name })
          end
        end
        entry
      end

      # The completed agreement that locked this version: its purchase
      # agreement, or the change order that made it LIVE.
      def signed_agreement(build)
        build.company.agreements.where(deal_id: build.deal_id, status: Agreement::STATUS_COMPLETED).order(completed_at: :desc, id: :desc)
             .find { |a| a.metadata.to_h.dig('buyer_change_order', 'to_build_id') == build.id || (purchase?(a) && !change_order?(a) && stamped_build(a)&.id == build.id) }
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
