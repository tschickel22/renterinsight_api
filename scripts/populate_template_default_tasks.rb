#!/usr/bin/env ruby
# Run: bin/rails runner scripts/populate_template_default_tasks.rb
# Populates default_tasks JSON on template phases so NEW projects get rich tasks

Company.find_each do |company|
  company.project_templates.active.each do |template|
    puts "Populating default_tasks for template: #{template.name} (Company #{company.id})"

    template.project_template_phases.order(:position).each do |phase|
      tasks = case phase.name
      when 'Finance Application'
        [
          { title: 'Submit loan application', task_type: 'general', estimated_hours: 2, checklist: ['Collect buyer financials', 'Run credit check', 'Submit to lender'] },
          { title: 'Receive pre-approval', task_type: 'milestone', estimated_hours: 1 },
        ]
      when 'Purchase Agreement Signed'
        [
          { title: 'Prepare purchase agreement', task_type: 'general', estimated_hours: 2, checklist: ['Buyer info complete', 'Home specs confirmed', 'Pricing finalized', 'Trade-in documented'] },
          { title: 'Buyer signs PA', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Collect deposit', task_type: 'general', estimated_hours: 1 },
        ]
      when /Home Ordered|In Production/
        [
          { title: 'Submit factory order', task_type: 'general', estimated_hours: 2 },
          { title: 'Color and option selections', task_type: 'general', estimated_hours: 4, checklist: ['Interior colors', 'Cabinet style', 'Countertops', 'Flooring', 'Siding and shingles', 'Appliances'] },
          { title: 'Confirm production schedule', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Monitor production status', task_type: 'general', estimated_hours: 2 },
        ]
      when 'Home Arrives at Dealer'
        [
          { title: 'Schedule transport from factory', task_type: 'general', estimated_hours: 2 },
          { title: 'Receive home on lot', task_type: 'milestone', estimated_hours: 4 },
          { title: 'Verify serial numbers and docs', task_type: 'general', estimated_hours: 1 },
        ]
      when /Receiving Inspection|PDI/
        [
          { title: 'Exterior inspection', task_type: 'inspection_required', estimated_hours: 2, checklist: ['Roof condition', 'Siding intact', 'Windows sealed', 'No transport damage'] },
          { title: 'Interior inspection', task_type: 'inspection_required', estimated_hours: 2, checklist: ['Walls and ceiling', 'Flooring', 'Plumbing fixtures', 'Electrical panels', 'Appliances'] },
          { title: 'Document deficiencies', task_type: 'general', estimated_hours: 1 },
          { title: 'Submit warranty claims', task_type: 'general', estimated_hours: 1 },
        ]
      when /Land Prep|Permits/
        [
          { title: 'Site evaluation and soil test', task_type: 'general', estimated_hours: 4, checklist: ['Soil bearing test', 'Drainage assessment', 'Grade evaluation', 'Access road check'] },
          { title: 'Building permit application', task_type: 'permit_required', estimated_hours: 2, checklist: ['Submit site plan', 'Submit foundation details', 'Submit utility plans', 'Pay permit fees'] },
          { title: 'Foundation construction', task_type: 'inspection_required', estimated_hours: 40, checklist: ['Forms set', 'Rebar placed', 'Concrete poured', 'Cure time complete', 'Anchors installed'] },
          { title: 'Foundation inspection', task_type: 'inspection_required', estimated_hours: 2 },
          { title: 'Utility trenching', task_type: 'general', estimated_hours: 16, checklist: ['Water line', 'Sewer line', 'Electric conduit', 'Gas line'] },
        ]
      when /Delivered to Site/
        [
          { title: 'Verify delivery path clearance', task_type: 'general', estimated_hours: 2, checklist: ['Road width ok', 'No low wires', 'Turn radius clear', 'Ground firm'] },
          { title: 'Home delivery and placement', task_type: 'milestone', estimated_hours: 8 },
          { title: 'Level and anchor home', task_type: 'general', estimated_hours: 8, checklist: ['Pier/block placement', 'Home leveled', 'Tie-downs secured'] },
          { title: 'Remove tires and axles', task_type: 'general', estimated_hours: 4 },
        ]
      when /Installation.*Set/
        [
          { title: 'Section joining and marriage line', task_type: 'general', estimated_hours: 16, checklist: ['Sections aligned', 'Gaskets sealed', 'Roof ridge connected', 'Floor alignment verified'] },
          { title: 'Skirting installation', task_type: 'general', estimated_hours: 12, checklist: ['Material installed', 'Access panels placed', 'Ventilation adequate'] },
          { title: 'Steps and deck', task_type: 'general', estimated_hours: 16 },
          { title: 'Exterior trim', task_type: 'general', estimated_hours: 8 },
        ]
      when /Utility Connection/
        [
          { title: 'Electrical connections', task_type: 'inspection_required', estimated_hours: 8, checklist: ['Panel connected', 'Crossovers done', 'All circuits tested', 'GFCI verified'] },
          { title: 'Electrical inspection', task_type: 'inspection_required', estimated_hours: 2 },
          { title: 'Plumbing connections', task_type: 'inspection_required', estimated_hours: 8, checklist: ['Water connected', 'Sewer connected', 'Crossovers done', 'Fixtures tested'] },
          { title: 'Plumbing inspection', task_type: 'inspection_required', estimated_hours: 2 },
          { title: 'HVAC installation', task_type: 'general', estimated_hours: 12, checklist: ['AC unit installed', 'Ductwork connected', 'Thermostat set', 'System tested'] },
        ]
      when /Interior Finish/
        [
          { title: 'Drywall marriage line close-up', task_type: 'general', estimated_hours: 16, checklist: ['Tape and texture seams', 'Repair transport cracks', 'Touch-up paint'] },
          { title: 'Interior trim', task_type: 'general', estimated_hours: 16 },
          { title: 'Carpet installation', task_type: 'general', estimated_hours: 8 },
          { title: 'Appliance install and test', task_type: 'general', estimated_hours: 8, checklist: ['Range connected', 'Refrigerator placed', 'Dishwasher connected', 'Washer/dryer hookups'] },
          { title: 'Final cleaning', task_type: 'general', estimated_hours: 8 },
        ]
      when /Final Inspection/
        [
          { title: 'Schedule final inspection', task_type: 'general', estimated_hours: 1 },
          { title: 'Final building inspection', task_type: 'inspection_required', estimated_hours: 4 },
          { title: 'Certificate of occupancy', task_type: 'milestone', estimated_hours: 1 },
        ]
      when /Punch List|Walk/
        [
          { title: 'Buyer walkthrough', task_type: 'general', estimated_hours: 4, checklist: ['All systems functioning', 'Cosmetic items noted', 'Punch list created', 'Keys provided'] },
          { title: 'Complete punch list items', task_type: 'general', estimated_hours: 8 },
          { title: 'Warranty docs reviewed', task_type: 'general', estimated_hours: 1, checklist: ['Manufacturer warranty', '30-day cosmetic window', '12-month start date'] },
        ]
      when /Closing|Handoff/
        [
          { title: 'Final payment collection', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Title transfer', task_type: 'general', estimated_hours: 2 },
          { title: 'Warranty registration', task_type: 'general', estimated_hours: 1 },
        ]
      when /Construction Authorized/
        [
          { title: 'Buyer authorizes construction', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Down payment confirmed non-refundable', task_type: 'general', estimated_hours: 1 },
        ]
      when /Color.*Option|Selection/
        [
          { title: 'Interior color selections', task_type: 'general', estimated_hours: 2, checklist: ['Walls', 'Trim', 'Doors', 'Cabinets', 'Countertops'] },
          { title: 'Exterior color selections', task_type: 'general', estimated_hours: 2, checklist: ['Siding', 'Shingles', 'Trim color', 'Shutters'] },
          { title: 'Appliance selections', task_type: 'general', estimated_hours: 1 },
        ]
      when /Home Completed/
        [
          { title: 'Factory completion confirmed', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Quality photos from factory', task_type: 'general', estimated_hours: 1 },
        ]
      when /Balance Due|Payment/
        [
          { title: 'Generate final invoice', task_type: 'general', estimated_hours: 1 },
          { title: 'Collect remaining balance', task_type: 'milestone', estimated_hours: 1 },
        ]
      when /Transport Scheduled/
        [
          { title: 'Book transport company', task_type: 'general', estimated_hours: 2 },
          { title: 'Arrange highway escorts', task_type: 'general', estimated_hours: 1 },
          { title: 'Confirm delivery date with buyer', task_type: 'general', estimated_hours: 1 },
        ]
      when /Delivered.*Title|Title Transfer/
        [
          { title: 'Home delivered to buyer', task_type: 'milestone', estimated_hours: 4 },
          { title: 'MSO/title transfer', task_type: 'general', estimated_hours: 2 },
          { title: 'Tires and axles bill of sale', task_type: 'general', estimated_hours: 1 },
        ]
      when /Finance Approved/
        [
          { title: 'Lender approval received', task_type: 'milestone', estimated_hours: 1 },
          { title: 'Verify loan terms with buyer', task_type: 'general', estimated_hours: 1 },
        ]
      when /Refurbishment/
        [
          { title: 'Assess repair needs', task_type: 'general', estimated_hours: 4, checklist: ['Structural check', 'Plumbing check', 'Electrical check', 'Cosmetic assessment'] },
          { title: 'Complete repairs', task_type: 'general', estimated_hours: 20 },
          { title: 'Quality inspection after repairs', task_type: 'inspection_required', estimated_hours: 2 },
        ]
      when /Site Preparation/
        [
          { title: 'Grade and level site', task_type: 'general', estimated_hours: 8 },
          { title: 'Foundation work', task_type: 'inspection_required', estimated_hours: 24 },
          { title: 'Utility rough-ins', task_type: 'general', estimated_hours: 16 },
        ]
      when /Delivery.*Set/
        [
          { title: 'Deliver and place home', task_type: 'milestone', estimated_hours: 8 },
          { title: 'Level, anchor, and skirt', task_type: 'general', estimated_hours: 12 },
          { title: 'Utility connections', task_type: 'inspection_required', estimated_hours: 16 },
        ]
      when /Warranty Period/
        [
          { title: 'Record warranty start date', task_type: 'general', estimated_hours: 1 },
          { title: 'Schedule 30-day follow-up', task_type: 'general', estimated_hours: 1 },
          { title: 'Schedule 6-month check-in', task_type: 'general', estimated_hours: 1 },
          { title: 'Schedule 11-month walk-through', task_type: 'general', estimated_hours: 1 },
        ]
      else
        []
      end

      if tasks.any?
        indexed = tasks.each_with_index.map { |t, i| t.merge(position: i) }
        phase.update_column(:default_tasks, indexed)
        print '.'
      end
    end
    puts " done"
  end
end

puts "\nAll template phases now have default_tasks populated."
puts "New projects created from these templates will include rich tasks with checklists."
