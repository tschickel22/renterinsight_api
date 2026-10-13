# frozen_string_literal: true

# The side menu items a company has hidden (Company Settings, Customize, Menu).
#
#   GET /api/v1/company/menu   { hidden: ["/contacts", "section:Projects"] }
#   PUT /api/v1/company/menu   { hidden: [...] }
#
# Hiding is presentation, not access: a hidden page still opens from a link,
# a bookmark or a record, and permissions are unchanged. So reading is open to
# everyone in the company, like labels (every menu draws with it), and only
# changing it needs company_settings:update.
class Api::V1::MenuSettingsController < ApplicationController
  before_action :set_company_scope

  SETTING_KEY = 'hidden_menu_items'
  # A menu item is its href; a whole section is "section:<name>".
  KEY_FORMAT = %r{\A(/[\w\-/]*|section:[\w &\-]+)\z}
  # Never hideable, so nobody can hide the way back to this setting.
  PROTECTED = ['/settings', 'section:Administration'].freeze
  MAX_ITEMS = 200

  def show
    render json: { hidden: self.class.hidden_for(@company) }
  end

  def update
    return unless authorize_action!('company_settings', 'update')

    hidden = Array(params[:hidden]).map { |k| k.to_s.strip }
                                   .select { |k| k.length <= 120 && k.match?(KEY_FORMAT) }
                                   .uniq - PROTECTED
    return render json: { error: "At most #{MAX_ITEMS} items can be hidden" }, status: :unprocessable_entity if hidden.size > MAX_ITEMS

    Setting.set('Company', @company.id, SETTING_KEY, hidden)
    render json: { hidden: hidden }
  end

  def self.hidden_for(company)
    Array(Setting.get('Company', company.id, SETTING_KEY, [])).map(&:to_s)
  end
end
