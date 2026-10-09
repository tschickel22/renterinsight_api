# frozen_string_literal: true

module Agreements
  # Installs a dealer's agreement package (a JSON file under
  # script/agreement_templates: their contract as a document model, the page
  # order and the fills) as one of their agreement templates. A re-run updates
  # it in place, so agreements already made from it keep their link.
  # Used by script/agreement_templates/*_packet.rb and the platform admin.
  class PackageInstaller
    DIR = Rails.root.join('script/agreement_templates')

    def self.available
      Dir[DIR.join('*_packet.json')].sort.map do |f|
        meta = JSON.parse(File.read(f)).slice('form', 'name', 'state', 'description')
        meta.merge('package' => File.basename(f, '_packet.json'))
      end
    end

    def self.load(package)
      raise ArgumentError, 'Unknown package' unless package.to_s.match?(/\A[a-z0-9_]+\z/)

      path = DIR.join("#{package}_packet.json")
      raise ArgumentError, "No package named #{package}" unless File.exist?(path)

      JSON.parse(File.read(path))
    end

    def initialize(company, package)
      @company = company
      @packet = self.class.load(package)
      missing = Array(@packet['order']) - @packet['doc'].to_h.keys - @packet['standard_sheets'].to_h.keys
      raise ArgumentError, "The package names pages it does not have: #{missing.join(', ')}" if missing.any?
    end

    attr_reader :packet

    def existing
      @company.agreement_templates.find_by(form_number: @packet['form'], is_platform_template: false, is_deleted: false)
    end

    def summary
      "#{existing ? "Update template ##{existing.id}" : 'Create'} \"#{@packet['name']}\" for #{@company.name}: " \
        "#{@packet['order'].size} sheets, #{@packet['fills'].to_h.size} blanks filled from the deal, signers #{Array(@packet['signers']).join(', ')}"
    end

    def install!
      template = existing || @company.agreement_templates.build(form_number: @packet['form'])
      template.assign_attributes(
        name: @packet['name'], description: @packet['description'], template_type: 'upload', status: 'active',
        form_type: 'purchase_agreement', state_code: @packet['state'], packet: @packet,
        default_signers: Array(@packet['signers']).each_with_index.map { |s, i| { 'role' => 'signer', 'order_index' => i, 'label' => s.humanize } },
        agreement_category: @company.agreement_categories.find_by(name: 'Sales Agreement') || template.agreement_category,
        is_platform_template: false, is_system_template: false, is_deleted: false
      )
      template.save!
      template
    end
  end
end
