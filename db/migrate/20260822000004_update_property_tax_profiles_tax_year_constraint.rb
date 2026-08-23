class UpdatePropertyTaxProfilesTaxYearConstraint < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :property_tax_profiles, name: "check_property_tax_profiles_tax_year_positive"
    add_check_constraint :property_tax_profiles,
                         "tax_year >= 1901 AND tax_year <= 2099",
                         name: "check_property_tax_profiles_tax_year_range"
  end

  def down
    remove_check_constraint :property_tax_profiles, name: "check_property_tax_profiles_tax_year_range"
    add_check_constraint :property_tax_profiles,
                         "tax_year > 1900",
                         name: "check_property_tax_profiles_tax_year_positive"
  end
end
