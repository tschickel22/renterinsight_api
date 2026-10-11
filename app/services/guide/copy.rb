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
  #                                  whose menu says "Prospects".
  module Copy
    BRAND_TOKEN = '{{brand}}'
    LABEL_TOKEN = /\{\{label:([a-z_]+)\|([^}]*)\}\}/

    def self.render(text, company: nil)
      return text unless text.is_a?(String) && text.include?('{{')

      out = text.include?(BRAND_TOKEN) ? text.gsub(BRAND_TOKEN, Brand.current(company: company).name.to_s) : text
      return out unless out.include?('{{label:')

      labels = company ? (company.resolved_labels rescue {}) || {} : {}
      out.gsub(LABEL_TOKEN) { labels[Regexp.last_match(1)].presence || Regexp.last_match(2) }
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
