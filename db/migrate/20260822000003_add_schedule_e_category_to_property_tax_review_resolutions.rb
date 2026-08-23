class AddScheduleECategoryToPropertyTaxReviewResolutions < ActiveRecord::Migration[8.1]
  def change
    add_column :property_tax_review_resolutions, :schedule_e_category, :string
  end
end
