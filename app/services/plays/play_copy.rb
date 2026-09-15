# frozen_string_literal: true

module Plays
  # A dealer's copy of a lead response play: "New Google lead" made from New
  # Facebook lead, with its own name, sources, starting tag and messages.
  #
  # The copy's definition is a PlayInstallation row with status 'copy'; installs
  # of the copy are ordinary rows under the same key. The play class is built
  # from that definition on demand, as a subclass of the play it copies, so
  # install, customize, the map, previews and results all work unchanged.
  module PlayCopy
    PREFIX = 'copy_'
    MAX_NAME = 60

    module_function

    def copy_key?(key)
      key.to_s.start_with?(PREFIX)
    end

    def definitions(company_id)
      PlayInstallation.where(company_id: company_id, status: 'copy').order(:id)
    end

    def find(company_id, key)
      return nil if company_id.nil?

      row = definitions(company_id).find_by(play_key: key.to_s)
      row && build(row)
    end

    def all(company_id)
      return [] if company_id.nil?

      definitions(company_id).filter_map { |row| build(row) }
    end

    def create!(company:, user:, base:, name:, sources:, start_tag:, content:)
      unless base.kind == 'lead_response' && !base.hidden?
        raise InstallError, 'Only a lead response play, like New Facebook lead or Walk-in visit, can be duplicated.'
      end

      name = name.to_s.strip
      raise InstallError, 'Name the new play.' if name.blank?
      raise InstallError, "Keep the name under #{MAX_NAME} characters." if name.length > MAX_NAME

      taken = (Registry.all + all(company.id)).map { |play| play::NAME.downcase }
      raise InstallError, "A play named #{name} already exists." if taken.include?(name.downcase)

      row = PlayInstallation.create!(
        company_id: company.id,
        play_key: "#{PREFIX}#{SecureRandom.hex(4)}",
        status: 'copy',
        installed_by_user_id: user&.id,
        answers: {
          'base' => base::KEY,
          'name' => name,
          'sources' => Array(sources).map { |source| source.to_s.strip }.reject(&:blank?).uniq,
          'start_tag' => base.normalize_tag(start_tag),
          'content' => base.normalize_content(content)
        }
      )
      build(row)
    end

    def build(row)
      meta = (row.answers || {}).deep_stringify_keys
      base = Registry.find(meta['base'])
      return nil unless base&.kind == 'lead_response'

      name = meta['name'].to_s
      sources = Array(meta['sources'])
      from = sources.any? ? " for new leads from #{sources.join(', ')}" : ''
      description = "A copy of #{base::NAME}#{from}: a first response from their rep, a call task, and follow-up " \
                    'emails if they go quiet, with its own messages and timing.'

      Class.new(base) do
        const_set(:KEY, row.play_key)
        const_set(:NAME, name)
        const_set(:DESCRIPTION, description)

        define_singleton_method(:copy?) { true }
        define_singleton_method(:base_play) { base }
        define_singleton_method(:hidden?) { false }
        define_singleton_method(:default_sources) { sources }
        define_singleton_method(:start_tag) { meta['start_tag'].presence }
        define_singleton_method(:default_content) { meta['content'].presence || base.default_content }
        # Its own form, named for the copy and filed under its first source.
        define_singleton_method(:forms) do
          sources.first ? [{ name: "#{name} Contact", source: sources.first, fields: :contact }] : []
        end
      end
    end
  end
end
