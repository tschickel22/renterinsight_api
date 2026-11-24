# frozen_string_literal: true

module Guide
  module Setup
    # A dealership's agreement templates, for the help assistant (E118 step 3):
    # each template's signer slots, and where each placed field gets its value
    # (Guide::FieldSources), so "where does buyer address come from" and "why
    # does the license box show the street" are answered from the template.
    # Never any values: templates can carry sensitive fields.
    class Agreements
      MAX = 15

      def initialize(ctx)
        @ctx = ctx
        @company = ctx.company
      end

      def to_h
        templates = @company.agreement_templates.where(is_deleted: [false, nil]).order(updated_at: :desc).limit(MAX + 1).to_a
        {
          templates: templates.first(MAX).map { |t| template(t) },
          more_templates: (templates.size > MAX ? 'there are more; ask about one by name' : nil),
          signer_slots_note: 'Signer boxes are tied to a slot (1, 2, 3...). Whoever is in that slot on the agreement fills ' \
                             'the boxes for it, so removing a signer moves the later ones up.'
        }.compact
      end

      private

      def template(t)
        placements = Array(t.merge_field_placements.presence || t.field_placements).map { |p| p.respond_to?(:to_h) ? p.to_h.stringify_keys : {} }
        slots = Array(t.default_signers).sort_by { |s| s.is_a?(Hash) ? s['order_index'].to_i : 0 }
                                        .map.with_index { |s, i| { slot: i + 1, label: s.is_a?(Hash) ? (s['label'] || s['role']) : s.to_s } }
        filled = placements.reject { |p| p['isSignerField'] }
        {
          name: t.name, status: t.status, form: [t.try(:form_type), t.try(:form_number)].compact.join(' ').presence,
          sensitive: t.try(:sensitive) ? true : nil, signer_slots: slots.presence,
          fields_filled_from: filled.group_by { |p| Guide::FieldSources.describe(p['fieldKey'], custom: p['isCustomField']) }
                                    .transform_values { |ps| ps.map { |p| p['fieldLabel'].presence || p['fieldKey'] }.uniq.first(12) },
          signer_boxes: placements.select { |p| p['isSignerField'] }
                                  .group_by { |p| "slot #{p['signerIndex'].to_i + 1}" }
                                  .transform_values { |ps| ps.map { |p| p['fieldLabel'].presence || p['fieldKey'] }.uniq.first(10) }.presence
        }.compact
      end
    end
  end
end
