Rails.application.config.to_prepare do
  begin
    controller = Api::Crm::LeadsController
    mod = Api::Crm::LeadsShowAndScore
    controller.include(mod) unless controller < mod
  rescue NameError => e
    # If controller or models aren't autoloaded yet, skip inclusion
    Rails.logger.info "Skipping LeadsController concern inclusion: #{e.message}"
  end
end
