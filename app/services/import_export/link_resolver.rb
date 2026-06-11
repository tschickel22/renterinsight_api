# frozen_string_literal: true

module ImportExport
  # Makes imports order-independent. Two responsibilities:
  #
  #   1. record_miss! -- when the Importer's lookup fails to find a parent, this
  #      persists a PendingImportLink describing the child, the FK column to fill,
  #      and how to find the parent later.
  #
  #   2. resolve_for_parent! -- when a new parent record is created during import,
  #      this finds pending links waiting on a parent of that model whose
  #      lookup_value matches the new record, and back-fills the child's FK.
  #
  # Matching mirrors Importer#find_lookup_record (including the first_name/
  # last_name name-aware path) so a deferred resolution links the same record
  # the in-line lookup would have.
  class LinkResolver
    # Lookup definitions (from ModuleRegistry) that target a given parent model.
    def self.lookup_defs_for_model(model_name)
      ModuleRegistry::LOOKUP_FIELDS.values.select { |d| d[:model].to_s == model_name.to_s }
    end

    def initialize(company, import_job: nil)
      @company = company
      @job     = import_job
    end

    # Persist an unresolved lookup so it can be back-filled later. `defn` is the
    # lookup definition hash from ModuleRegistry.lookup_fields_for.
    def record_miss!(child_record:, defn:, lookup_value:)
      return if child_record.nil? || child_record.id.nil?
      return if lookup_value.to_s.strip.empty?

      PendingImportLink.create!(
        company:       @company,
        entity_type:   child_record.class.name,
        entity_id:     child_record.id,
        target_column: defn[:target_column].to_s,
        parent_model:  defn[:model].to_s,
        match_fields:  Array(defn[:search_fields]).map(&:to_s),
        lookup_value:  lookup_value.to_s.strip,
        lookup_key:    defn[:key]&.to_s,
        import_job:    @job,
        status:        'pending'
      )
    rescue StandardError => e
      Rails.logger.warn "[ImportExport::LinkResolver] record_miss! failed: #{e.message}"
      nil
    end

    # Called after a parent record is created. Finds pending links that this
    # parent satisfies and back-fills the waiting children. Returns the count
    # of links resolved.
    def resolve_for_parent!(parent_record)
      return 0 if parent_record.nil? || parent_record.id.nil?

      model_name = parent_record.class.name
      candidates = PendingImportLink
                   .pending
                   .where(company_id: @company.id, parent_model: model_name)

      return 0 if candidates.empty?

      resolved = 0
      candidates.find_each do |link|
        next unless parent_matches?(parent_record, link)

        child = link.entity_record
        if child.nil?
          # Child was deleted before resolution; retire the stale link.
          link.update!(status: 'abandoned')
          next
        end

        # Don't clobber a value that was set in the meantime.
        if child.respond_to?(link.target_column) &&
           child.public_send(link.target_column).blank?
          apply_fk!(child, link.target_column, parent_record.id)
          resolved += 1
        end

        link.mark_resolved!(parent_record)
      end

      resolved
    end

    # Sweep all pending links for the company against existing parents. Useful
    # as a one-shot reconciliation after a full onboarding (or to re-link records
    # uploaded in a later session). Scoped to the company; optionally limited to
    # a single parent model.
    def reconcile_all!(parent_models: nil)
      models = parent_models || PendingImportLink
               .pending.where(company_id: @company.id)
               .distinct.pluck(:parent_model)

      total = 0
      Array(models).each do |model_name|
        klass = model_name.to_s.safe_constantize
        next unless klass

        values = PendingImportLink.pending
                                  .where(company_id: @company.id, parent_model: model_name)
                                  .distinct.pluck(:lookup_value)
        next if values.empty?

        base = klass.respond_to?(:where) ? klass.where(company_id: @company.id) : nil
        next unless base

        base.find_each do |parent|
          total += resolve_for_parent!(parent)
        end
      end
      total
    end

    private

    # Writes the FK and persists without re-running notifications/webhooks/etc.
    # Uses update_column to avoid touching validations or callbacks on a record
    # that was already validated at import time.
    def apply_fk!(child, column, parent_id)
      child.update_column(column, parent_id)
    rescue StandardError => e
      Rails.logger.warn "[ImportExport::LinkResolver] apply_fk! #{child.class}##{child.id}.#{column}=#{parent_id} failed: #{e.message}"
    end

    # Does this parent satisfy the pending link's stored lookup? Mirrors the
    # Importer's matching: exact, then case-insensitive, with first_name/
    # last_name combo handling for people-like parents.
    def parent_matches?(parent, link)
      fields = Array(link.match_fields)
      value  = link.lookup_value.to_s.strip
      return false if value.empty? || fields.empty?

      if fields.include?('first_name') && fields.include?('last_name')
        return name_matches?(parent, value)
      end

      fields.any? do |f|
        next false unless parent.respond_to?(f)
        attr = parent.public_send(f).to_s
        attr.casecmp?(value)
      end
    end

    # Mirrors Importer#find_by_name for the deferred path: "Benny Smith",
    # "benny smith", single name, or full-name concat.
    def name_matches?(parent, value)
      first = parent.respond_to?(:first_name) ? parent.first_name.to_s : ''
      last  = parent.respond_to?(:last_name)  ? parent.last_name.to_s  : ''
      full  = "#{first} #{last}".strip

      parts = value.split(/\s+/, 2)
      if parts.length >= 2
        return true if first.casecmp?(parts[0]) && last.casecmp?(parts[1])
      end
      return true if full.casecmp?(value)
      return true if !first.empty? && first.casecmp?(value)
      return true if !last.empty?  && last.casecmp?(value)

      false
    end
  end
end
