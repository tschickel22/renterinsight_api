# frozen_string_literal: true

module Accounting
  module QboMigration
    # The older QuickBooks record sync (QuickbooksSyncService: customers,
    # vendors, invoices, payments, purchase orders, inventory, credit memos),
    # set per company or per location under Settings > Integrations >
    # QuickBooks. Not bank feeds.
    #
    # While a switch is open (a draft, a posted trial or a posted live switch)
    # it stays off for the company and every location: during a trial what it
    # sent to QuickBooks would also be typed there, and once DealerTide is the
    # books anything it fetched would come in twice. A switch turns it off when
    # it starts (Wizard.start!) and again when it posts; rolling back puts it
    # back as it was. Settings screens and the sync itself refuse while locked.
    module OldSync
      module_function

      def records(company)
        [company] + company.locations.to_a
      end

      # [{ record:, on: [record types], auto_sync: bool }] for each place with any sync on.
      def places_on(company)
        records(company).filter_map do |rec|
          settings = (rec.quickbooks_settings || {}).deep_stringify_keys
          on = (settings['entities'] || {}).select { |_k, v| v.is_a?(Hash) && truthy?(v['enabled']) }.keys
          auto = truthy?(settings['auto_sync'])
          next if on.empty? && !auto

          { record: rec, on: on, auto_sync: auto }
        end
      end

      def summary(company)
        places = places_on(company).map { |p| place_json(p[:record], p[:on], p[:auto_sync]) }
        { on: places.any?, places: places }
      end

      def place_json(rec, on, auto)
        { type: rec.is_a?(Location) ? 'location' : 'company', id: rec.id, name: rec.name, entities: on, auto_sync: auto ? true : false }
      end

      # Turns every record type and automatic sync off for the company and
      # each location. Returns what each place held before, for restore!.
      def turn_off!(company)
        places_on(company).map do |p|
          rec = p[:record]
          before = rec.quickbooks_settings
          turn_off_record!(rec)
          { 'type' => rec.is_a?(Location) ? 'location' : 'company', 'id' => rec.id, 'settings' => before,
            'name' => rec.name, 'entities' => p[:on], 'auto_sync' => p[:auto_sync] }
        end
      end

      def turn_off_record!(rec)
        settings = (rec.quickbooks_settings || {}).deep_stringify_keys
        entities = settings['entities'] || {}
        entities.each_key { |k| entities[k] = entities[k].merge('enabled' => false) if entities[k].is_a?(Hash) }
        settings['entities'] = entities if entities.any?
        settings['auto_sync'] = false
        rec.update_column(:quickbooks_settings, settings)
      end

      def restore!(company, before)
        # The first record of a place is what it held before any switch touched it.
        Array(before).uniq { |p| [p['type'], p['id']] }.each do |place|
          rec = place['type'] == 'location' ? company.locations.find_by(id: place['id']) : company
          rec&.update_column(:quickbooks_settings, place['settings'])
        end
      end

      # The switch that keeps the sync off, or nil.
      def lock(company)
        company.accounting_imports.migrations.where(status: %w[draft posted]).order(:id).last
      end

      def lock_message(company)
        import = lock(company)
        return nil unless import

        if import.status == 'draft'
          'The QuickBooks sync stays off while your switch from QuickBooks is in progress, so nothing reaches QuickBooks twice.'
        elsif import.import_config&.dig('trial')
          'The QuickBooks sync stays off during your QuickBooks trial: QuickBooks is still your books and you enter everything ' \
            'there, so anything sent from here would be in QuickBooks twice. It comes back if the trial is rolled back.'
        else
          "The QuickBooks sync stays off because #{Brand.current(company: company).name} is now your books " \
            "(switched from QuickBooks as of #{import.cutover_date&.strftime('%B %-d, %Y')}). QuickBooks keeps past years only. " \
            'Rolling back the switch turns it on again.'
        end
      end

      # Whether a settings change would turn any of the sync on.
      def enabling?(settings)
        s = (settings || {}).to_h.deep_stringify_keys
        return true if truthy?(s['auto_sync'])

        (s['entities'] || {}).values.any? { |v| v.is_a?(Hash) && truthy?(v['enabled']) }
      end

      def truthy?(value)
        ActiveModel::Type::Boolean.new.cast(value) ? true : false
      end
    end
  end
end
