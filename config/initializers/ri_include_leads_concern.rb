Rails.application.config.to_prepare do
  begin
    controller = Api::Crm::LeadsController
    mod = Api::Crm::LeadsShowAndScore
    controller.include(mod) unless controller < mod
  rescue NameError
    # If controller isn’t autoloaded yet, force it and retry
    require Rails.root.join('app/controllers/api/crm/leads_controller.rb')
    retry
  end
end
