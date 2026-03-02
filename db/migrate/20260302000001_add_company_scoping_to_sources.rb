# frozen_string_literal: true

class AddCompanyScopingToSources < ActiveRecord::Migration[8.0]
  def up
    # Guard: add company_id column only if missing
    unless column_exists?(:sources, :company_id)
      add_column :sources, :company_id, :bigint
      add_index :sources, :company_id
    end

    # Add composite index for company-scoped queries ordered by created_at
    unless index_exists?(:sources, [:company_id, :created_at])
      add_index :sources, [:company_id, :created_at], name: 'index_sources_on_company_id_and_created_at'
    end

    # Backfill: for each nil-company source, create company-specific copies
    # and reassign leads/deals to the new copies
    backfill_nil_sources
  end

  def down
    remove_index :sources, name: 'index_sources_on_company_id_and_created_at', if_exists: true
  end

  private

  def backfill_nil_sources
    nil_sources = Source.where(company_id: nil)
    return if nil_sources.empty?

    say "Found #{nil_sources.count} sources with nil company_id - backfilling..."

    nil_sources.each do |source|
      # Find all companies that reference this source via leads or deals
      lead_company_ids = Lead.where(source_id: source.id).distinct.pluck(:company_id).compact
      deal_company_ids = Deal.where(source_id: source.id).distinct.pluck(:company_id).compact
      company_ids = (lead_company_ids + deal_company_ids).uniq

      if company_ids.empty?
        say "  Source ##{source.id} '#{source.name}' - no leads/deals, deleting orphan"
        source.destroy
        next
      end

      if company_ids.size == 1
        # Only one company uses it - just assign it
        say "  Source ##{source.id} '#{source.name}' -> assigning to company #{company_ids.first}"
        source.update_column(:company_id, company_ids.first)
      else
        # Multiple companies - duplicate for each
        company_ids.each_with_index do |cid, idx|
          if idx == 0
            # Reuse the original for the first company
            say "  Source ##{source.id} '#{source.name}' -> assigning to company #{cid}"
            source.update_column(:company_id, cid)
          else
            # Create a copy for subsequent companies
            new_source = Source.create!(
              name: source.name,
              source_type: source.source_type,
              tracking_code: source.tracking_code,
              is_active: source.is_active,
              company_id: cid
            )
            say "  Source ##{source.id} '#{source.name}' -> duplicated as ##{new_source.id} for company #{cid}"

            # Reassign leads and deals for this company to the new source
            Lead.where(source_id: source.id, company_id: cid).update_all(source_id: new_source.id)
            Deal.where(source_id: source.id, company_id: cid).update_all(source_id: new_source.id)
          end
        end
      end
    end

    remaining = Source.where(company_id: nil).count
    say "Backfill complete. Remaining nil sources: #{remaining}"
  end
end
