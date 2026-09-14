# frozen_string_literal: true

module Campaigns
  # Makes the tags an audience filter names real, then rewrites tag leaves to
  # tag ids.
  #
  # Shared by the AI builder and the template gallery. A tag that does not
  # exist makes FilterCompiler's tag join return nobody, and the tag never
  # shows up for a rep to apply, so a seeded template filtering on
  # "weekly-digest-email" enrolled no one on a company that had never made it.
  class AudienceTags
    def initialize(company:, description: 'Auto-created from campaign audience')
      @company = company
      @description = description
    end

    # Mutates filter_tree in place and returns it.
    def prepare!(filter_tree)
      ensure_exist!(filter_tree)
      normalize!(filter_tree)
      filter_tree
    end

    # Collect any tag names referenced by tag conditions (operator starts with
    # 'tags_') and find_or_create each one on this company. Ids are left alone:
    # a numeric id that doesn't exist is a caller bug, and the enroller should
    # skip it rather than fabricate a tag.
    def ensure_exist!(node)
      return unless node.is_a?(Hash)
      names = Set.new
      collect_names(node, names)
      return if names.empty?
      names.each do |raw|
        name = raw.to_s.strip
        next if name.blank?
        # Match TagsController#create semantics: name is scoped by
        # company_id and case-sensitive.
        next if @company.tags.find_by(name: name)
        @company.tags.create(
          name: name,
          description: @description,
          color: '#6B7280',
          is_active: true,
          is_system: false
        )
      end
    end

    # Patch tag leaves in place so the persisted tree matches what
    # CampaignBuilder authors manually. Runs AFTER ensure_exist! so the tags
    # are guaranteed to exist and be resolvable by name.
    def normalize!(node)
      return unless node.is_a?(Hash)
      is_tag_leaf = node['field'].to_s == 'tags' || node['operator'].to_s.start_with?('tags_')
      if is_tag_leaf
        # Default the operator if it was omitted; the UI shows an empty
        # operator picker otherwise. Multi-value defaults to tags_any_of,
        # single-value to tags_include.
        if node['operator'].to_s.empty? || !node['operator'].to_s.start_with?('tags_')
          node['operator'] = node['value'].is_a?(Array) && node['value'].length > 1 ? 'tags_any_of' : 'tags_include'
        end
        node['field'] = 'tags'
        # Rewrite name-strings to ids so the FE tag chip displays the label.
        # FilterCompiler handles either shape, but the FE tag dropdown keys
        # tags by id.
        rewritten = Array(node['value']).map { |v|
          if v.is_a?(Integer) || (v.is_a?(String) && v =~ /\A\d+\z/)
            v.to_i
          elsif v.is_a?(String)
            tag = @company.tags.find_by(name: v.strip)
            tag ? tag.id : v
          else
            v
          end
        }
        # Preserve scalar-vs-array shape: tags_include takes a scalar,
        # tags_any_of takes an array.
        node['value'] = node['operator'] == 'tags_any_of' ? rewritten : rewritten.first
      end
      Array(node['children']).each { |c| normalize!(c) }
    end

    private

    def collect_names(node, into)
      return unless node.is_a?(Hash)
      op = node['operator'].to_s
      # A leaf with field="tags" but no operator counts as a tag condition too,
      # so the tag is created even when the operator was forgotten.
      if op.start_with?('tags_') || (op.empty? && node['field'].to_s == 'tags')
        Array(node['value']).each do |v|
          # Numeric strings/ints are ids, skip them.
          next if v.is_a?(Integer)
          next if v.is_a?(String) && v =~ /\A\d+\z/
          into << v if v.is_a?(String)
        end
      end
      Array(node['children']).each { |c| collect_names(c, into) }
    end
  end
end
