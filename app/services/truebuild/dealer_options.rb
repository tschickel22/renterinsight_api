# frozen_string_literal: true

module Truebuild
  # A dealer's own changes to a factory's options (backlog E85): colors they
  # added, book colors they hid, and their names for book options. Each is
  # saved once and used on every Deal Sheet after, and each goes to the
  # platform admin as a CatalogOptionRequest (Truebuild::OptionRequests
  # applies it for everyone, keeps it for the dealer, or turns it down).
  #
  # A dealer color is a catalog option with company_id set and no price book
  # row, so wherever a model's options are listed (the Deal Sheet's order
  # form and Colors checklist, the factory PO, Schedule A) it joins as a row
  # built in memory beside the book's, in every color set the model offers.
  # Hidden colors drop out, except one already picked on the sheet in front
  # of the rep.
  #
  # A factory book can carry one color as several options, one per series
  # (Champion's Topeka book has Shutters "Black" seven times). A dealer means
  # the color, not one series' copy, so hiding or renaming a color covers
  # every copy of it in its set (key_for).
  class DealerOptions
    def initialize(company, manufacturer_id)
      @company = company
      @manufacturer_id = manufacturer_id
    end

    # The dealer's active colors for this manufacturer.
    def colors
      @colors ||= @company.dealer_colors.where(manufacturer_id: @manufacturer_id, kind: 'color', status: 'active').includes(:group).to_a
    end

    # A color's set and name: what its copies across series share. Nil for
    # anything that is not a color in a set.
    def self.key_for(option)
      set = option.kind == 'color' ? option.metadata.to_h['color_set'].presence : nil
      set && [set, option.name.to_s.strip.downcase]
    end

    # Every copy of a factory color in its set (just the option itself when
    # it is not a color in a set).
    def self.twins(option)
      key = key_for(option)
      return CatalogOption.where(id: option.id) unless key

      CatalogOption.platform.where(manufacturer_id: option.manufacturer_id, kind: 'color')
                   .where("metadata->>'color_set' = ?", key[0]).where('LOWER(TRIM(name)) = ?', key[1])
    end

    # Did the dealer take this book color off their lists?
    def hidden?(option)
      hidden_ids.include?(option.id) || ((key = self.class.key_for(option)) && hidden_keys.include?(key))
    end

    def renamed?(option)
      names.key?(option.id) || ((key = self.class.key_for(option)) && name_keys.key?(key))
    end

    def name_for(option)
      names[option.id] || ((key = self.class.key_for(option)) && name_keys[key]) || option.name
    end

    # A line's name, as DealBuild.option_label writes it, in the dealer's words.
    def label_for(option)
      set = DealBuild.choice_set(option)
      name = name_for(option).to_s
      set && !name.downcase.start_with?(set.downcase) ? "#{set}: #{name}" : name
    end

    # rows: a model's offered book rows (OptionSource.offered). keep_ids:
    # options to keep though hidden (picked on the sheet).
    def apply(rows, keep_ids: [])
      keep = keep_ids.to_set
      rows = rows.reject { |op| !keep.include?(op.catalog_option_id) && hidden?(op.option) } if hidden_ids.any?
      sets = rows.filter_map { |op| DealBuild.choice_set(op.option) }.to_set
      return rows if sets.empty? || colors.empty?

      rows + colors.select { |o| sets.include?(DealBuild.choice_set(o)) }.map { |o| self.class.row_for(o) }
    end

    # A dealer color by id, or nil.
    def color(id)
      colors.find { |o| o.id == id.to_i }
    end

    # An unsaved price row for a dealer color: never written, only read.
    def self.row_for(option)
      meta = option.metadata.to_h
      cost = meta['cost'].presence&.to_d
      CatalogOptionPrice.new(option: option, catalog_option_id: option.id, dealer_cost: cost,
                             suggested_retail: meta['retail'].presence&.to_d, is_standard: cost.nil? || cost.zero?)
    end

    # The color sets a manufacturer's book uses, each with its options: a
    # dealer's new color in a set is filed in the group of the first. A set
    # is either color options (color_set) or standard choices named for it,
    # "3 Tab Shingles: Black Weatherwood" (Dutch Housing's Topeka book), as
    # DealBuild.choice_set reads them.
    def self.sets(manufacturer_id)
      CatalogOption.platform.where(manufacturer_id: manufacturer_id, status: 'active')
                   .where("(kind = 'color' AND metadata->>'color_set' IS NOT NULL) OR kind = 'standard'")
                   .includes(:group).order(:id).to_a
                   .group_by { |o| DealBuild.choice_set(o) }.except(nil)
    end

    # Adds a color of the dealer's own to a set and sends it to the platform
    # admin. replaces_id: a book color in the same set to hide at the same
    # time (Black Weatherwood replaced by Black and Weatherwood).
    def self.add_color!(company:, manufacturer_id:, color_set:, name:, user: nil, factory_code: nil, cost: nil, retail: nil,
                        replaces_id: nil, deal: nil, note: nil)
      name = name.to_s.squish
      raise ArgumentError, 'Name the color' if name.blank?

      sibling = sets(manufacturer_id)[color_set]&.first
      raise ArgumentError, "#{color_set} is not a color set for this manufacturer" unless sibling

      CatalogOption.transaction do
        existing = company.dealer_colors.where(manufacturer_id: manufacturer_id, kind: 'color', status: 'active')
                          .where("metadata->>'color_set' = ?", color_set).where('LOWER(name) = ?', name.downcase).first
        option = existing || company.dealer_colors.create!(
          manufacturer_id: manufacturer_id, group: sibling.group, kind: 'color', name: name,
          key: "dealer-#{company.id}-#{color_set.parameterize}-#{name.parameterize}-#{SecureRandom.hex(3)}",
          factory_code: factory_code.to_s.strip.upcase.presence,
          metadata: money_meta(cost, retail).merge('color_set' => color_set)
        )
        unless existing
          company.catalog_option_requests.create!(manufacturer_id: manufacturer_id, option: option, action: 'add', color_set: color_set,
                                                  deal: deal, requested_by: user, note: note.presence)
        end
        hide!(company: company, option_id: replaces_id, user: user, deal: deal, note: "Replaced by #{name}") if replaces_id.present?
        option
      end
    end

    # Changes a dealer color's name, code, cost or price. Its request to the
    # admin stays as it is: the admin applies what the color is by then.
    def self.update_color!(option, attrs)
      attrs = attrs.to_h.symbolize_keys
      option.name = attrs[:name].to_s.squish if attrs[:name].present?
      option.factory_code = attrs[:factory_code].to_s.strip.upcase.presence if attrs.key?(:factory_code)
      meta = option.metadata.to_h
      %i[cost retail].each do |k|
        next unless attrs.key?(k)

        attrs[k].blank? ? meta.delete(k.to_s) : meta[k.to_s] = money(attrs[k])
      end
      option.metadata = meta.deep_stringify_keys
      option.save!
      option
    end

    # Retires a dealer color. Sheets that picked it keep the pick.
    def self.remove_color!(option, user: nil)
      CatalogOption.transaction do
        option.update!(status: 'discontinued', discontinued_on: Date.current)
        withdraw(option.company.catalog_option_requests.where(catalog_option_id: option.id).in_force, user)
      end
    end

    # Hides a book color from the dealer's lists and sends it to the admin.
    def self.hide!(company:, option_id:, user: nil, deal: nil, note: nil)
      option = CatalogOption.platform.find_by(id: option_id)
      raise ArgumentError, 'That is not a factory color' unless option && DealBuild.choice_set(option)
      return if company.catalog_option_requests.in_force.exists?(action: 'hide', catalog_option_id: twins(option).select(:id))

      company.catalog_option_requests.create!(manufacturer_id: option.manufacturer_id, option: option, action: 'hide',
                                              color_set: DealBuild.choice_set(option), deal: deal, requested_by: user,
                                              note: note.presence)
    end

    def self.unhide!(company:, option_id:, user: nil)
      option = CatalogOption.find_by(id: option_id)
      ids = option ? twins(option).select(:id) : option_id
      withdraw(company.catalog_option_requests.in_force.where(action: 'hide', catalog_option_id: ids), user)
    end

    # The dealer's name for an option. Their own color is simply renamed; a
    # book option keeps the book's name for everyone else, and the new name
    # goes to the admin. A blank name, or the book's own, goes back to it.
    def self.rename!(company:, option:, name:, user: nil, deal: nil, note: nil)
      name = name.to_s.squish
      if option.dealer_color?
        raise ArgumentError, 'That color is not yours' unless option.company_id == company.id
        raise ArgumentError, 'Name the color' if name.blank?

        return option.update!(name: name)
      end

      CatalogOptionRequest.transaction do
        withdraw(company.catalog_option_requests.in_force.where(action: 'rename', catalog_option_id: twins(option).select(:id)), user)
        next nil if name.blank? || name == option.name

        company.catalog_option_requests.create!(manufacturer_id: option.manufacturer_id, option: option, action: 'rename',
                                                name: name, color_set: DealBuild.choice_set(option), deal: deal,
                                                requested_by: user, note: note.presence)
      end
    end

    def self.withdraw(scope, user)
      scope.update_all(status: 'withdrawn', resolved_at: Time.current, resolved_by_id: user&.id, updated_at: Time.current)
    end

    def self.money_meta(cost, retail)
      { 'cost' => cost.presence && money(cost), 'retail' => retail.presence && money(retail) }.compact
    end

    def self.money(value)
      amount = BigDecimal(value.to_s.delete(',$'))
      raise ArgumentError, 'An amount cannot be negative' if amount.negative?

      amount.round(2).to_s('F')
    rescue ArgumentError, TypeError => e
      raise if e.message.start_with?('An amount')

      raise ArgumentError, "#{value} is not an amount"
    end

    private

    def hidden_ids
      @hidden_ids ||= requests.select { |r| r.action == 'hide' }.map(&:catalog_option_id).to_set
    end

    def hidden_keys
      @hidden_keys ||= requests.select { |r| r.action == 'hide' }.filter_map { |r| r.option && self.class.key_for(r.option) }.to_set
    end

    # { option_id => the dealer's name } for book options they renamed.
    def names
      @names ||= requests.select { |r| r.action == 'rename' }.to_h { |r| [r.catalog_option_id, r.name] }
    end

    def name_keys
      @name_keys ||= requests.select { |r| r.action == 'rename' }
                             .filter_map { |r| (key = r.option && self.class.key_for(r.option)) && [key, r.name] }.to_h
    end

    def requests
      @requests ||= @company.catalog_option_requests.in_force.where(manufacturer_id: @manufacturer_id).includes(:option).order(:created_at).to_a
    end
  end
end
