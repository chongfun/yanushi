class UpdateRentalPropertyTypesToScheduleE < ActiveRecord::Migration[8.1]
  def up
    # Old enum: commercial: 0, residential: 1
    # New enum: commercial: 4, single_family_residence: 1
    # We only need to update commercial records from 0 to 4.
    # Residential records are already 1, which will map to single_family_residence.
    execute "UPDATE rental_properties SET property_type = 4 WHERE property_type = 0"
  end

  def down
    execute "UPDATE rental_properties SET property_type = 0 WHERE property_type = 4"
    # Note: Other types (2, 3, 5-8) don't have a clean mapping back,
    # but we'll leave them as is or they would error on old enum anyway.
  end
end
