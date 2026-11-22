# frozen_string_literal: true

# One-time fill for the deal people card (Tom, 2026-11-22).
#
# The card (entity_buyers) and the deal's Buyer / Co-Buyer columns
# (contact_id, co_applicant_contact_id) used to be set separately. Now they
# follow each other, and the card fills itself from the columns when it is
# opened. This task does the same for every deal at once (quotes and invoices
# made later copy the card), and handles the other direction:
#
#   * Columns set, card empty for that role   -> put the person on the card.
#   * Card has a Buyer/Co-Buyer, column empty -> set the column from the card.
#   * Both set, different people              -> REPORTED, never written.
#     A person decides which is right (CONFLICT lines). Settle one with
#     DEAL_ID=<id> KEEP=card|columns APPLY=1.
#
# DRY-RUN by default. APPLY=1 writes. COMPANY_ID=<id> scopes.
#
#   bin/rails deals:sync_people
#   COMPANY_ID=17 APPLY=1 bin/rails deals:sync_people
#   DEAL_ID=123 KEEP=card APPLY=1 bin/rails deals:sync_people
namespace :deals do
  desc 'Fill the deal people card from the Buyer/Co-Buyer columns and back; lists disagreements. DRY-RUN unless APPLY=1.'
  task sync_people: :environment do
    apply = ENV['APPLY'] == '1'
    scope = Deal.where(deleted_at: nil)
    scope = scope.where(company_id: ENV['COMPANY_ID']) if ENV['COMPANY_ID'].present?
    scope = scope.where(id: ENV['DEAL_ID']) if ENV['DEAL_ID'].present?
    keep = ENV['KEEP'].presence

    puts "[deals:sync_people] mode=#{apply ? 'APPLY' : 'DRY-RUN'} company=#{ENV['COMPANY_ID'] || 'ALL'}#{" deal=#{ENV['DEAL_ID']} keep=#{keep}" if ENV['DEAL_ID']}"
    tally = Hash.new(0)
    name = ->(id) { id && Contact.where(id: id).pick(Arel.sql("TRIM(CONCAT(first_name, ' ', last_name))")) }

    scope.find_each do |deal|
      conflicts = deal.people_conflicts
      if conflicts.any?
        conflicts.each do |c|
          if keep && ENV['DEAL_ID'].present?
            puts "  deal #{deal.id} #{c[:role]}: keeping #{keep}"
            next unless apply

            if keep == 'card'
              deal.sync_pointers_from_people!([c[:role]])
            else
              column = Deal::PEOPLE_POINTERS[c[:role]]
              deal.entity_buyers.active.where(role: c[:role]).where.not(contact_id: deal[column]).update_all(is_deleted: true, updated_at: Time.current)
              deal.ensure_people_from_pointers!
            end
            tally[:settled] += 1
          else
            puts "  CONFLICT company #{deal.company_id} deal #{deal.id} #{c[:role]}: columns say #{c[:column_contact_id]} #{name.(c[:column_contact_id])}, card says #{c[:card_contact_id]} #{name.(c[:card_contact_id])}"
            tally[:conflicts] += 1
          end
        end
        next
      end

      card_roles = deal.entity_buyers.active.distinct.pluck(:role)
      missing_on_card = Deal::PEOPLE_POINTERS.select { |role, col| deal[col].present? && !card_roles.include?(role) }.keys
      missing_column = Deal::PEOPLE_POINTERS.select { |role, col| deal[col].blank? && card_roles.include?(role) }.keys
      next if missing_on_card.empty? && missing_column.empty?

      tally[:card_filled] += 1 if missing_on_card.any?
      tally[:columns_filled] += 1 if missing_column.any?
      next unless apply

      Deal.transaction do
        deal.ensure_people_from_pointers! if missing_on_card.any?
        deal.sync_pointers_from_people!(missing_column) if missing_column.any?
      end
    end

    puts "[deals:sync_people] cards to fill: #{tally[:card_filled]}, columns to fill: #{tally[:columns_filled]}, " \
         "disagreements: #{tally[:conflicts]}#{", settled: #{tally[:settled]}" if tally[:settled].positive?}#{' (dry run, nothing written)' unless apply}"
  end
end
