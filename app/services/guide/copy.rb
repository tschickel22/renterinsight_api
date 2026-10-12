# frozen_string_literal: true

module Guide
  # Help and tour copy is stored as data, so it cannot call the brand kernel
  # or a dealer's labels the way a view does. Two tokens are filled in when the
  # copy is served:
  #
  #   {{brand}}                      the platform name (brand kernel)
  #   {{label:leads|Prospecting}}    this dealer's word for leads, else the
  #                                  default after the bar. Dealers rename
  #                                  menu items; tour text that said
  #                                  "Prospecting" was wrong for a dealer
  #                                  whose menu says "Prospects". A lowercase
  #                                  default ({{label:deal|deal}}) asks for
  #                                  the word in lowercase, mid-sentence.
  module Copy
    BRAND_TOKEN = '{{brand}}'
    LABEL_TOKEN = /\{\{label:([a-z_]+)\|([^}]*)\}\}/

    def self.render(text, company: nil)
      return text unless text.is_a?(String) && text.include?('{{')

      out = text.include?(BRAND_TOKEN) ? text.gsub(BRAND_TOKEN, Brand.current(company: company).name.to_s) : text
      return out unless out.include?('{{label:')

      labels = company ? (company.resolved_labels rescue {}) || {} : {}
      out.gsub(LABEL_TOKEN) do
        fallback = Regexp.last_match(2)
        label = labels[Regexp.last_match(1)].presence
        next fallback unless label

        # A lowercase default means the word sits mid-sentence ("open the
        # deal"), where a menu label's capital ("Deal") reads wrong.
        fallback.match?(/\A[a-z]/) ? lowercase_words(label) : label
      end
    end

    # "Sales Deal" becomes "sales deal"; an acronym such as RV stays.
    def self.lowercase_words(text)
      text.split(' ').map { |w| w.match?(/\A[A-Z0-9]{2,}\z/) ? w : w.downcase }.join(' ')
    end

    # Every string inside an Atlas entry (title, where-step text, breadcrumb),
    # filled in for one company.
    def self.render_deep(value, company: nil)
      case value
      when String then render(value, company: company)
      when Array then value.map { |v| render_deep(v, company: company) }
      when Hash then value.transform_values { |v| render_deep(v, company: company) }
      else value
      end
    end
  end
end
