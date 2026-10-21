# frozen_string_literal: true

module Websites
  # The intake forms a company's website pages submit to, most used first.
  #
  # A page names its form in its own column or inside a block's settings
  # (contact blocks write formId, inventory cards lead_form_id, and older
  # blocks other spellings). A play asking "which form is on your website"
  # needs the form visitors actually fill in, not whichever one is newest.
  class FormsInUse
    BLOCK_FORM_KEYS = /"(?:formId|intakeFormId|leadFormId|lead_form_id|form_id|intake_form_id)":\s*"?(\d+)/

    def self.ids_for(company)
      return [] if company.nil?

      pages = WebsitePage.joins(:website).where(websites: { company_id: company.id })
      ids = pages.where.not(intake_form_id: nil).pluck(:intake_form_id)
      pages.pluck(:blocks).each { |blocks| blocks.to_json.scan(BLOCK_FORM_KEYS) { |(id)| ids << id.to_i } }

      # Only this company's forms: a block can carry any number.
      own = company.intake_forms.where(id: ids.uniq).pluck(:id)
      ids.select { |id| own.include?(id) }.tally.sort_by { |id, count| [-count, id] }.map(&:first)
    rescue StandardError => e
      Rails.logger.warn("[Websites::FormsInUse] lookup failed for #{company&.id}: #{e.message}")
      []
    end
  end
end
