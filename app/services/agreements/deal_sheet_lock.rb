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
    # Out with the buyers: sent and not yet completed, voided or expired.
    OPEN = [Agreement::STATUS_SENT, Agreement::STATUS_VIEWED, Agreement::STATUS_PARTIALLY_SIGNED].freeze

    class << self
      # A purchase agreement: made with Create agreement, or from a purchase
      # agreement template. Other paperwork on a deal does not lock the sheet.
      def purchase?(agreement)
        agreement.metadata.to_h['packet'].present? || agreement.agreement_template&.form_type == 'purchase_agreement'
      end

      def change_order?(agreement) = agreement.metadata.to_h['buyer_change_order'].present?

      # The agreement out with the buyers on this version, if any: a purchase
      # agreement made from it, or a change order to or from it. While one is
      # out the version cannot change, become LIVE or stop being LIVE, or be
      # unlocked: the buyers must sign what the sheet says.
      def out_for_signature(build)
        return nil unless build&.deal_id

        build.company.agreements.where(deal_id: build.deal_id, status: OPEN).order(:id).find do |a|
          if change_order?(a)
            co = a.metadata.to_h['buyer_change_order']
            [co['to_build_id'], co['from_build_id']].include?(build.id)
          else
            purchase?(a) && a.metadata.to_h.dig('deal_sheet', 'build_id') == build.id
          end
        end
      end

      # Why this version cannot change now, or nil.
      def edit_problem(build)
        return "#{build.version_name} is locked by a signed agreement; change it with a change order" if build.locked?

        out = out_for_signature(build)
        return nil unless out

        "#{out.agreement_number} is out for signature on #{build.version_name}. " \
          'Void it first to change the sheet, then make a new one.'
      end

      # Called once the agreement is completed. A version locks only when it
      # still holds what the buyers signed; anything else is recorded on the
      # agreement for a person to sort out, never locked in silently.
      def completed(agreement)
        return apply_change_order(agreement) if change_order?(agreement)
        return unless purchase?(agreement)

        build = stamped_build(agreement)
        return unless build

        problem = if !build.live? then "#{build.version_name} is no longer the LIVE version"
                  elsif Agreement.deal_sheet_stamp(build)['digest'] != agreement.metadata.to_h.dig('deal_sheet', 'digest')
                    "#{build.version_name} changed after the agreement was made"
                  end
        return flag(agreement, problem) if problem

        build.update!(status: 'locked')
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
        if (out = out_for_signature(build))
          raise ArgumentError, "#{out.agreement_number} is out for signature on this version. Void it before unlocking."
        end

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

      # A signed change order applies only to the signed LIVE version it was
      # made against, with the draft as it was when made.
      def apply_change_order(agreement)
        co = agreement.metadata.to_h['buyer_change_order']
        builds = agreement.company.deal_home_builds
        from = builds.find_by(id: co['from_build_id'])
        to = builds.find_by(id: co['to_build_id'])
        problem = if !from || !to || to.deal_id != agreement.deal_id then 'the versions it changes are gone'
                  elsif !(from.live? && from.locked?) then "#{from.version_name} is no longer the signed LIVE version"
                  elsif Agreement.deal_sheet_stamp(to)['digest'] != co['to_digest'] then "#{to.version_name} changed after the change order was made"
                  end
        return flag(agreement, problem) if problem

        BuyerChangeOrder.apply!(agreement)
      end

      def flag(agreement, problem)
        Rails.logger.warn("[DealSheetLock] Agreement #{agreement.id} signed but not applied: #{problem}")
        agreement.update_columns(metadata: agreement.metadata.to_h.merge(
          'deal_sheet_not_applied' => { 'at' => Time.current.iso8601, 'reason' => "Signed, but the Deal Sheet was not changed: #{problem}." }
        ))
        nil
      end

      def stamped_build(agreement)
        id = agreement.metadata.to_h.dig('deal_sheet', 'build_id')
        id && agreement.company.deal_home_builds.find_by(id: id)
      end
    end
  end
end
